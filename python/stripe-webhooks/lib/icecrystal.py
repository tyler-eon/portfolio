import socket
from time import time
from typing import Optional


def worker_id_from_parts(parts):
    return parts[2] << 8 | parts[3]


# Generate a worker id based on the host's private IP address.
#
# If the host has multiple private IP addresses, the first one will be used.
#
# If no private IP addresses are found, an exception will be raised.
def worker_id_from_host():
    list = socket.getaddrinfo(socket.gethostname(), 8000)

    for _family, _type, _proto, _cname, addr in list:
        if len(addr) > 2:
            continue
        (host, _port) = addr  # pyright: ignore [reportAssignmentType]
        parts = [int(p) for p in host.split(".")]
        if parts[0] == 10:
            return worker_id_from_parts(parts)
        if parts[0] == 172:
            if parts[1] >= 16 and parts[1] <= 31:
                return worker_id_from_parts(parts)
        if parts[0] == 192:
            if parts[1] == 168:
                return worker_id_from_parts(parts)
    else:
        raise Exception("Could not determine worker ID")


# A Snowflake ID is an integer composed of the following parts:
#
# - 41 bits for the timestamp in milliseconds since a chosen epoch
# - 10 bits for the worker ID
# - 12 bits for the sequence number
#
# The Snowflake ID was a concept created by (OG) Twitter as a method to generate unique IDs at high scale in a distributed system.
#
# To ensure uniqueness even when multiple machines generate IDs at the same time, the Snowflake ID is based on a timestamp of *when* the ID was generated in relation to the chosen epoch as is modified by a worker ID and a sequence number.
#
# Assuming each worker id has a single generator running, we can assume that it can maintain uniqueness for 4096 IDs per millisecond (2^12 bits for a sequence number).
#
# Additionally, we can have up to 1024 generators running at the same time (2^10 bits for a worker ID).
#
# The timestamp is capable of representation in only 41 bits because we intentionally shift the time based on a selected epoch. This means the timestamp for August 1, 2023 when the selected epoch is January 1, 2020, will only be 113,007,600 milliseconds rather than 1,690,873,200 milliseconds when using the Unix epoch. But this also imposes a limit on the lifespan of the generator by allowing no more than ~70 years of IDs to be generated. For most purposes that is probably sufficient, and before that time comes there should be plenty of opportunity to migrate to a new generator.
class Snowflake(int):
    # Returns the *offset* in milliseconds since the epoch.
    @property
    def timestamp(self):
        return self >> 22

    # Returns the worker id that generated this Snowflake.
    @property
    def worker_id(self):
        return (self >> 12) & 0x3FF

    # Returns the sequence number for this Snowflake.
    @property
    def sequence(self):
        return self & 0xFFF


# A Snowflake ID generator.
#
# Because this relies on an internal sequence counter to ensure uniqueness, it is not thread-safe.
#
# It is recommended to use the `global` keyword to ensure all references to a given generator are the same instance and share the same sequence counter.
class SnowflakeGenerator:
    # Constructs a new Snowflake generator with the given epoch, worker ID, start time, and initial sequence number.
    #
    # The epoch is represented as a Unix timestamp in milliseconds and defaults to 1640995200000 (January 1, 2022).
    #
    # The start_time is the time at which the last id was generated, relative to the given epoch. So if the start time should equal the epoch, this value should be 0.
    def __init__(
        self,
        epoch: int = 1640995200000,
        worker_id: Optional[int] = None,
        start_time: int = 0,
        sequence: int = 0,
    ):
        self.epoch = epoch
        self.worker_id = self.ensure_worker_id(worker_id)
        self.last_timestamp = start_time
        self.sequence = sequence

    # If the worker ID is not provided, attempt to determine it from the private IP address of the machine.
    def ensure_worker_id(self, worker_id: int | None):
        if worker_id is not None:
            return worker_id
        return worker_id_from_host()

    # Generates a new Snowflake ID based on the current state of the generator.
    def next_id(self):
        timestamp = int(time() * 1000)
        if timestamp < self.last_timestamp:
            raise Exception("Clock moved backwards")
        if timestamp == self.last_timestamp:
            self.sequence = (self.sequence + 1) & 4095
            if self.sequence == 0:
                timestamp = self.wait_for_next_millis(timestamp)
        else:
            self.sequence = 0
        self.last_timestamp = timestamp
        return Snowflake(
            ((timestamp - self.epoch) << 22) | (self.worker_id << 12) | self.sequence
        )

    # Waits until the next millisecond, then returns the current timestamp.
    #
    # If we somehow reach the maximum sequence number in a single millisecond, we *must* wait until the next millisecond or we will generate a duplicate ID.
    def wait_for_next_millis(self, timestamp: int):
        # In theory, timestamp should never be less than self.last_timestamp, but let's just err on the side of caution.
        while timestamp <= self.last_timestamp:
            timestamp = int(time() * 1000)
        return timestamp
