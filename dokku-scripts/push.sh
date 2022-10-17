#!/bin/sh

# Phil Budne, September 2022
# Push current branch to Dokkku app instance
# DOES NOT NEED TO BE RUN AS ROOT!!!

# tmp files to clean up on exit
REMOTES=/tmp/remotes$$
trap "rm -f $REMOTES" 0

# hostname w/o any domain
HOSTNAME=$(hostname --short)

# get logged in user (even if su(do)ing)
# (lookup utmp entry for name of tty from stdio)
# will lose if run non-interactively via ssh (no utmp entry)
LOGIN_USER=$(who am i | awk '{ print $1 }')
if [ "x$LOGIN_USER" = x ]; then
    # XXX fall back to whoami (look by uid)
    echo could not find login user 2>&1
    exit 1
fi

# using localhost causes host key pain if NFS same mounted repo
# used from multiple servers in cluster
# XXX use untrimmed hostname (w/o -s)? with --fqdn??
SSH_USER="dokku@$HOSTNAME"

# avoids needing to sudo to root:
alias dokku="ssh $SSH_USER"

if ! git diff --quiet; then
    echo 'changes not checked in' 1>&2
    # XXX display diffs, or just dirty files??
    exit 1
fi

BRANCH=$(git branch --show-current)

# check if origin (ie; user github fork) not up to date
if git diff --quiet origin/$BRANCH --; then
    echo "origin/$BRANCH up to date"
else
    # have an option to override this??
    echo "origin/$BRANCH not up to date.  push!"
    exit 1
fi

# DOKKU_GIT_REMOTE: Name of git remote for Dokku
#	contains hostname because using HOSTNAME in SSH_USER
#	to allow use on multiple server mounting same NFS repo.
#	(Can run staging anywhere)
# PUSH_TAG_TO: other remotes to push tag to
PUSH_TAG_TO="origin"

git remote -v > $REMOTES

case "$BRANCH" in
prod|staging)
    # check if corresponding branch in mediacloud acct up to date

    # get remote for mediacloud account
    # ONLY match ssh remote, since will want to push tag.
    MCREMOTE=$(awk '/github\.com:mediacloud\// { print $1; exit }' $REMOTES)
    if [ "x$MCREMOTE" = x ]; then
	echo could not find a git remote for mediacloud org repo
	exit 1
    fi

    # check if MCREMOTE up to date.
    #    XXX sufficient if current commit part of remote branch???
    #
    #    http://codecook.io/git/214/check-if-specific-commit-is-on-remote
    #    "git branch -r --contains commit_sha" lists branches?
    #
    #    https://stackoverflow.com/questions/5549479/git-check-if-commit-xyz-in-remote-repo
    #    has "git log --cherry-pick --left-right <commitish> ^remote/branchname"

    if git diff --quiet $BRANCH $MCREMOTE/$BRANCH --; then
	echo "$MCREMOTE $BRANCH branch up to date."
    else
	# pushing to mediacloud repo should NOT be optional
	# for production or staging!!!
	echo "$MCREMOTE $BRANCH branch not up to date.  push first!!"
	exit 1
    fi
    # push tag back to github mediacloud branch
    PUSH_TAG_TO="$PUSH_TAG_TO $MCREMOTE"

    # name of git remote for dokku git server for $BRANCH on $HOSTNAME server.
    # this is likely overkill, at least for production, since it's reasonable
    # to expect only one production environment to exist, so maybe just
    # "dokku_$BRANCH"??
    DOKKU_GIT_REMOTE="dokku_${HOSTNAME}_$BRANCH"

    ;;
*)
    DOKKU_GIT_REMOTE="dokku_${HOSTNAME}_$LOGIN_USER"
    ;;
esac

# name of deploy branch in DOKKU_GIT_REMOTE repo
DOKKU_GIT_BRANCH=main

case $BRANCH in
prod) APP=rss-fetcher;;
staging) APP=staging-rss-fetcher;;
*) APP=${LOGIN_USER}-rss-fetcher;;
esac

if ! dokku apps:exists "$APP" >/dev/null 2>&1; then
    echo "app $APP not found" 1>&2
    exit 1
fi

TAB='	'
if ! grep "^$DOKKU_GIT_REMOTE$TAB" $REMOTES >/dev/null; then
    echo adding git remote $DOKKU_GIT_REMOTE
    # XXX prompt first?
    git remote add $DOKKU_GIT_REMOTE $SSH_USER:$APP
    # XXX exit on failure?
fi

git fetch $DOKKU_GIT_REMOTE
# have a --push-if-no-changes option?
if git diff --quiet $BRANCH $DOKKU_GIT_REMOTE/$DOKKU_GIT_BRANCH --; then
    echo no changes 1>&2
    exit
fi

# XXX log all commits not in Dokku repo??
echo "Last commit:"
git log -n1

# XXX display URL for DOKKU_GIT_REMOTE??
echo -n "Push branch $BRANCH to $DOKKU_GIT_REMOTE dokku app $APP? [no] "
read CONFIRM
case "$CONFIRM" in
[yY]|[yY][eE][sS]) ;;
*) echo '[cancelled]'; exit;;
esac

if [ "x$BRANCH" = xprod ]; then
    # XXX check if pushed to github/mediacloud/PROJECT prod branch??
    # (for staging too?)

    echo -n "This is production! Type YES to confirm: "
    read CONFIRM
    if [ "x$CONFIRM" != 'YES' ]; then
       echo '[cancelled]'
       exit
    fi

    TAG=v$(grep '^VERSION' fetcher/__init__.py | sed -e 's/^.*=//' -e 's/"//g' -e "s/'//g")
    # NOTE! fgrep -x (-F -x) to match literal whole line (w/o regexps)
    if git tag | grep -F -x "$TAG" >/dev/null; then
	echo "found local tag $TAG: update fetcher.VERSION?"
	# XXX need a --force-tag option?
	exit 1
    fi

    # https://stackoverflow.com/questions/5549479/git-check-if-commit-xyz-in-remote-repo
    for REMOTE in origin $DOKKU_GIT_REMOTE $MCREMOTE; do
	if git fetch $REMOTE $TAG >/dev/null; then
	    echo "found $REMOTE tag $TAG: update fetcher.VERSION?"
	    exit 1
	fi
    done
else
    # XXX use staging or $USER instead of full $APP for brevity?
    TAG=$(date -u '+%F-%H-%M-%S')-$HOSTNAME-$APP
fi
echo adding $TAG
git tag $TAG

echo "pushing $BRANCH to git remote $DOKKU_GIT_REMOTE branch $DOKKU_GIT_BRANCH"
# NOTE: push will complain if you (developer) switch branches
# (or your branch has been perturbed upstream, ie; by a force push)
# so add script option to enable --force to push to dokku git repo?

# NOTE! pushing tag first time causes mayhem (reported by Rahul at
# https://github.com/dokku/dokku/issues/5188)
#
# perhaps explained by https://dokku.com/docs/deployment/methods/git/
#	"As of 0.22.1, Dokku will also respect the first pushed branch
#	as the primary branch, and automatically set the deploy-branch
#	value at that time."
# (ISTR seeing refs/tags/..../refs/tags/....)

if git log -n1 $DOKKU_GIT_REMOTE/$DOKKU_GIT_BRANCH -- >/dev/null 2>&1; then
    # not first push, safe to push by tag name
    git push $DOKKU_GIT_REMOTE $BRANCH:$TAG
else
    # first push for new app.
    git push $DOKKU_GIT_REMOTE $BRANCH:$DOKKU_GIT_BRANCH

    # will see complaints "WARNING: deploy did not complete, you must push to main."
    echo "first push: pushing tag $TAG (ignore WARNING)"
    # just redirect all output???
    git push $DOKKU_GIT_REMOTE $TAG
fi

# push tag to upstream repos
for REMOTE in $PUSH_TAG_TO; do
    echo pushing tag $TAG to $REMOTE
    git push $REMOTE $TAG
done

SCALE=""
# start fetcher first (the first time); resets the queue
for CC in fetcher=1 worker=8; do
    set $(echo $CC | sed 's/=/ /')
    CONTAINER=$1
    COUNT=$2

    # only needed once (non-idempotent)
    CURR=$(dokku ps:report $APP | grep "Status $CONTAINER [1-9]" | wc -l)
    if [ $COUNT != $CURR ]; then
	SCALE="$SCALE $CONTAINER=$COUNT"
    else
	echo "found $CURR $CONTAINER(s)"
    fi
done

if [ "x$SCALE" != x ]; then
    # here if found processes to scale
    echo ps:scale $APP $SCALE
    dokku ps:scale $APP $SCALE
fi
