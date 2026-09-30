"""Tests for the visitor counter API (Cloud Resume Challenge, step 11).

These tests never touch Azure. Instead of a real Cosmos DB table, they use
FakeTableClient, a small stand-in that behaves like the parts of
azure.data.tables.TableClient our code uses. That keeps the tests fast, free,
and runnable in GitHub Actions without any secrets.

Run from the api folder with:  pytest -v
"""
import json

import azure.functions as func
import pytest
from azure.core import MatchConditions
from azure.core.exceptions import ResourceModifiedError
from azure.data.tables import TableEntity

import function_app


# ---------------------------------------------------------------------------
# Test doubles
# ---------------------------------------------------------------------------

class FakeTableClient:
    """Pretends to be a Cosmos DB table holding one counter entity.

    conflicts: how many update attempts should fail as if another visitor
               changed the counter first (simulates a race condition).
    count:     starting value, or None to simulate an entity with no count.
    """

    def __init__(self, count=0, conflicts=0):
        self.count = count
        self.etag = "etag-0"
        self.conflicts_remaining = conflicts
        self.get_calls = 0
        self.update_calls = []

    def get_entity(self, partition_key, row_key):
        self.get_calls += 1
        data = {"PartitionKey": partition_key, "RowKey": row_key}
        if self.count is not None:
            data["count"] = self.count
        entity = TableEntity(**data)
        entity._metadata = {"etag": self.etag}  # real entities carry their ETag here
        return entity

    def update_entity(self, entity, mode, etag, match_condition):
        self.update_calls.append({"etag": etag, "match_condition": match_condition})
        if self.conflicts_remaining > 0:
            self.conflicts_remaining -= 1
            self.etag = f"etag-changed-{self.conflicts_remaining}"
            raise ResourceModifiedError("The entity was modified by someone else")
        if etag != self.etag:
            raise ResourceModifiedError("Stale ETag")
        self.count = entity["count"]
        self.etag = f"etag-{self.count}"


def call_api(method="POST"):
    """Invoke the HTTP function the same way the Functions host would."""
    request = func.HttpRequest(
        method=method,
        url="/api/visitorcount",
        body=b"",
        headers={},
    )
    user_function = function_app.visitor_count.build().get_user_function()
    return user_function(request)


# ---------------------------------------------------------------------------
# increment_count(): the business logic
# ---------------------------------------------------------------------------

def test_increments_from_zero():
    table = FakeTableClient(count=0)
    assert function_app.increment_count(table) == 1
    assert table.count == 1


def test_increments_existing_value():
    table = FakeTableClient(count=41)
    assert function_app.increment_count(table) == 42
    assert table.count == 42


def test_entity_without_count_starts_at_one():
    table = FakeTableClient(count=None)
    assert function_app.increment_count(table) == 1


def test_update_is_conditional_on_etag():
    """The write must only succeed if nobody changed the counter since we read it."""
    table = FakeTableClient(count=5)
    etag_we_read = table.etag
    function_app.increment_count(table)
    call = table.update_calls[0]
    assert call["etag"] == etag_we_read
    assert call["match_condition"] == MatchConditions.IfNotModified


def test_retries_when_another_visitor_wins_the_race():
    table = FakeTableClient(count=10, conflicts=2)
    assert function_app.increment_count(table) == 11
    assert table.get_calls == 3        # read, conflict, re-read, conflict, re-read, success
    assert len(table.update_calls) == 3


def test_gives_up_after_max_retries():
    table = FakeTableClient(count=10, conflicts=100)
    with pytest.raises(RuntimeError):
        function_app.increment_count(table)
    assert len(table.update_calls) == function_app.MAX_RETRIES
    assert table.count == 10           # nothing was written


# ---------------------------------------------------------------------------
# visitor_count(): the HTTP layer
# ---------------------------------------------------------------------------

def test_http_returns_new_count_as_json(monkeypatch):
    table = FakeTableClient(count=99)
    monkeypatch.setattr(function_app, "get_table_client", lambda: table)

    response = call_api()

    assert response.status_code == 200
    assert response.mimetype == "application/json"
    assert json.loads(response.get_body()) == {"count": 100}


def test_http_error_is_generic_and_leaks_nothing(monkeypatch):
    """Internal error details belong in the logs, never in the response."""
    secret_detail = "AccountKey=supersecret; Endpoint=https://internal"

    def broken_client():
        raise Exception(secret_detail)

    monkeypatch.setattr(function_app, "get_table_client", broken_client)

    response = call_api()
    body = response.get_body().decode()

    assert response.status_code == 500
    assert json.loads(body) == {"error": "Unable to update count"}
    assert "supersecret" not in body
    assert "Traceback" not in body


def test_missing_connection_string_returns_500(monkeypatch):
    monkeypatch.delenv("COSMOS_CONNECTION_STRING", raising=False)
    response = call_api()
    assert response.status_code == 500
