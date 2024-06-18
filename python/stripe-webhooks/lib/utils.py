from typing import Any


__all__ = ("MISSING",)


class _MissingSentinel:
    __slots__ = ()

    def __eq__(self, other):
        return False

    def __bool__(self):
        return False

    def __hash__(self):
        return 0

    def __repr__(self):
        return "MISSING"


MISSING: Any = _MissingSentinel()
"""
MISSING is a sentinel object used as a placeholder for missing values. This allows us to type hint that a value may be missing, without making everything nullable.
"""
