# XXX use pidfile lock & clear next_fetch_attempt on command line feeds???
"""
"direct drive" feed fetcher: runs fetches in subprocesses using
fetcher.direct without queuing so that the exact number of concurrent
requests for a given source can be managed directly by
fetcher.headhunter.
"""

import logging
import time
from typing import Any, Dict, List, Optional

# PyPI:
from sqlalchemy import update

# app
from fetcher.config import conf
from fetcher.database import Session
from fetcher.database.models import Feed, utc
from fetcher.direct import Manager, Worker
from fetcher.headhunter import HeadHunter, Item, ready_feeds
from fetcher.logargparse import LogArgumentParser
from fetcher.stats import Stats
from fetcher.tasks import feed_worker

DEBUG_COUNTERS = False
SCRIPT = 'fetcher'
logger = logging.getLogger(SCRIPT)

if __name__ == '__main__':
    task_timeout = conf.TASK_TIMEOUT_SECONDS

    p = LogArgumentParser(SCRIPT, 'Feed Fetcher')
    # XXX add pid to log formatting????

    workers = conf.RSS_FETCH_WORKERS
    p.add_argument('--workers', default=workers, type=int,
                   help=f"number of worker processes (default: {workers})")

    # XXX take command line args for concurrency, fetches/sec

    # positional arguments:
    p.add_argument('feeds', metavar='FEED_ID', nargs='*', type=int,
                   help='Fetch specific feeds and exit.')

    args = p.my_parse_args()       # parse logging args, output start message

    hunter = HeadHunter()

    stats = Stats.get()

    # here for access to hunter!
    class FetcherWorker(Worker):
        def fetch(self, item: Item) -> None:  # called in Worker to do work
            """
            passed entire item (as dict) for use by fetch_done
            """
            # print("fetch", item, "***")
            feed_worker(item)

        def fetch_done(self, ret: Dict) -> None:  # callback in Manager
            # print("fetch_done", ret)
            item = ret['args'][0]  # recover "fetch" first arg (dict)
            hunter.completed(item)

    # XXX pass command line args for concurrency, fetches/sec??
    manager = Manager(args.workers, FetcherWorker)

    def worker_stats() -> None:
        stats.gauge('workers.active', manager.active_workers)
        stats.gauge('workers.current', manager.cworkers) # current
        stats.gauge('workers.n', manager.nworkers) # goal
        if DEBUG_COUNTERS:
            print('workers.active', manager.active_workers)
            print('workers.current', manager.cworkers) # current
            print('workers.n', manager.nworkers) # goal

    if args.feeds:
        # force feed with feed ids from command line
        hunter.refill(args.feeds)
    else:
        # clear all Feed.queued columns
        with Session() as session:
            res = session.execute(
                update(Feed)
                .values(queued=False)
                .where(Feed.queued.is_(True)))
            # res.rowcount is number of effected rows?
            session.commit()

    next_wakeup = 0.0
    worker_stats()
    while hunter.have_work():
        # here initially, or after manager.poll()
        t0 = time.time()

        worker_stats()
        looked_for_work = False
        loops = 0
        while w := manager.find_available_worker():
            elapsed = time.time() - t0
            loops += 1
            if elapsed > 10 or loops > 10:
                # XXX want to make sure stats reported often enough!
                logger.info(f"looking for work, {elapsed:.2f} sec elapsed, {loops} loops")

            looked_for_work = True
            item = hunter.find_work()
            if item is None:    # no issuable work available
                break

            # NOTE! returned item has been already been marked as
            # "issued" by headhunter

            feed_id = item['id']
            with Session() as session:
                # "queued" now means "currently being fetched"
                res = session.execute(
                    update(Feed)
                    .where(Feed.id == feed_id)
                    .values(queued=True))
                # res.rowcount is number of effected rows?
                hunter.get_ready(session)
                session.commit()

            w.call('fetch', item) # call method in child process
            worker_stats()

        if not looked_for_work:
            hunter.check_stale()
            print("need to force stats reporting?")

        # Wake up once a minute: find_work() will re fetch the
        # ready_list if stale.  Will wake up early if a worker
        # finishes a feed.  NOT sleeping until next next_fetch_attempt
        # so that changes (new feeds and triggered fetch) get picked
        # up.

        # calculate next wakeup time based on when we last woke
        next_wakeup = t0 - (t0 % 60) + 60
        # sleep until then:
        stime = next_wakeup - time.time()
        manager.poll(stime)

    # here when feeds given command line
    while manager.active_workers > 0:
        manager.poll()