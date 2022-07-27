import datetime as dt
import logging
from jinja2 import Template
import os
import html
from email.utils import formatdate  # RFC 822 date format
from typing import Optional

from fetcher import base_dir, VERSION

logger = logging.getLogger(__file__)

template_path = os.path.join(base_dir, 'fetcher', 'rss')


def _escape(text: Optional[str]) -> str:
    # return a safe text string for XML output
    if text is None:
        return ''
    output = html.unescape(text)  # cleanup while we are in here
    output = output.replace("&", "&amp;")
    output = output.replace("<", "&lt;")
    output = output.replace(">", "&gt;")
    return output


def add_header(file, today: dt.date) -> str:
    with open(os.path.join(template_path, "header.template")) as f:
        template_str = f.read()
    tm = Template(template_str)
    content = tm.render(day=today.strftime("%Y-%m-%d"), now=formatdate(), version=VERSION)
    file.write(content)
    return content


def add_item(file, link: str, pub_date: dt.datetime, domain: str, title: Optional[str]) -> str:
    with open(os.path.join(template_path, "item.template")) as f:
        template_str = f.read()
    tm = Template(template_str)
    content = tm.render(link=_escape(link), pub_date=formatdate(pub_date), domain=_escape(domain),
                        title=_escape(title))
    file.write(content)
    file.write(content)
    return content


def add_footer(file) -> str:
    with open(os.path.join(template_path, "footer.template")) as f:
        template_str = f.read()
    tm = Template(template_str)
    content = tm.render()
    file.write(content)
    return content