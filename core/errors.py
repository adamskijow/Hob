# SPDX-License-Identifier: MIT
"""Expected edge failures that should be retried without losing user intent."""


class RetryableMessageError(RuntimeError):
    """The message is valid but a temporary dependency prevented processing."""
