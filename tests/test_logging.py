# SPDX-License-Identifier: MIT
import logging
import os

from app import _PrivateRotatingFileHandler


def test_rotating_log_is_bounded_and_every_generation_is_owner_only(tmp_path):
    log_path = tmp_path / "hob.log"
    original_umask = os.umask(0)
    handler = _PrivateRotatingFileHandler(
        str(log_path), maxBytes=120, backupCount=3, encoding="utf-8"
    )
    try:
        handler.setFormatter(logging.Formatter("%(message)s"))
        logger = logging.getLogger("hob.test.private-rotation")
        logger.handlers = [handler]
        logger.propagate = False
        logger.setLevel(logging.INFO)
        for index in range(30):
            logger.info("private task-free diagnostic line %s", index)
    finally:
        handler.close()
        os.umask(original_umask)

    generations = sorted(tmp_path.glob("hob.log*"))
    assert 2 <= len(generations) <= 4
    assert all(path.stat().st_mode & 0o777 == 0o600 for path in generations)
