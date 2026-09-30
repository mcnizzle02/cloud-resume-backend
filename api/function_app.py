"""Visitor counter API for leemcnutt.dev (Cloud Resume Challenge, steps 9-10).

POST /api/visitorcount -> increments the counter in Cosmos DB (Table API)
                          and returns {"count": <new value>}
"""
import json
import logging
import os

import azure.functions as func
from azure.core import MatchConditions
from azure.core.exceptions import (
    ResourceExistsError,
    ResourceModifiedError,
    ResourceNotFoundError,
)
from azure.data.tables import TableClient, UpdateMode

# Anonymous because the browser calls this directly. A function key embedded in
# public JavaScript would be visible to every visitor, so it wouldn't protect
# anything. We restrict access with CORS on the Function App instead.
app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)

TABLE_NAME = "Counter"
PARTITION_KEY = "resume"
ROW_KEY = "visits"
MAX_RETRIES = 5


def get_table_client() -> TableClient:
    """Build a client from the connection string stored in app settings.

    The secret lives in local.settings.json (locally, gitignored) or in the
    Function App's configuration (in Azure) - never in this file.
    """
    conn_str = os.environ["COSMOS_CONNECTION_STRING"]
    return TableClient.from_connection_string(conn_str, table_name=TABLE_NAME)


def increment_count(table_client) -> int:
    """Read the counter, add one, and write it back safely.

    If the counter doesn't exist yet, it is created with a value of 1.

    Uses the entity's ETag for optimistic concurrency: the write only succeeds
    if nobody else changed the counter since we read it. If two visitors hit
    the site at the same moment, the loser of the race re-reads and retries
    instead of overwriting the other visit.
    """
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            entity = table_client.get_entity(partition_key=PARTITION_KEY, row_key=ROW_KEY)
        except ResourceNotFoundError:
            # First visit on a freshly deployed database: create the counter.
            # Infrastructure as code builds the table, but not the data in it.
            try:
                table_client.create_entity(
                    {"PartitionKey": PARTITION_KEY, "RowKey": ROW_KEY, "count": 1}
                )
                return 1
            except ResourceExistsError:
                # Another visitor created it a moment before us; go back and
                # increment it through the normal path instead.
                continue

        entity["count"] = int(entity.get("count", 0)) + 1
        try:
            table_client.update_entity(
                entity,
                mode=UpdateMode.REPLACE,
                etag=entity.metadata["etag"],
                match_condition=MatchConditions.IfNotModified,
            )
            return entity["count"]
        except ResourceModifiedError:
            logging.warning("Counter changed during update, retrying (attempt %d)", attempt)
    raise RuntimeError(f"Could not update counter after {MAX_RETRIES} attempts")


@app.route(route="visitorcount", methods=["POST"])
def visitor_count(req: func.HttpRequest) -> func.HttpResponse:
    try:
        count = increment_count(get_table_client())
    except Exception:
        # Full details go to the logs; the caller gets a generic message.
        logging.exception("Failed to update visitor count")
        return func.HttpResponse(
            json.dumps({"error": "Unable to update count"}),
            status_code=500,
            mimetype="application/json",
        )

    return func.HttpResponse(
        json.dumps({"count": count}),
        status_code=200,
        mimetype="application/json",
    )
