import logging
import os
from typing import Any, Dict

from pythonjsonlogger import jsonlogger


# Straight copy from Spark.
class MyFormatter(jsonlogger.JsonFormatter):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)

    def add_fields(
        self,
        log_record: Dict[str, Any],
        record: logging.LogRecord,
        message_dict: Dict[str, Any],
    ):
        super().add_fields(log_record, record, message_dict)

        if "level" not in log_record:
            log_record["level"] = record.levelname

        if "module" not in log_record:
            log_record["module"] = record.name


def setup_logging():
    logger = logging.getLogger()
    logHandler = logging.StreamHandler()
    formatter = MyFormatter(timestamp=True)
    logHandler.setFormatter(formatter)
    logger.addHandler(logHandler)
    logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))
