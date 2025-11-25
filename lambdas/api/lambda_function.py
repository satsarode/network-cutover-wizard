import json
import os
import uuid
from datetime import datetime, timezone

import boto3

dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["PROJECTS_TABLE"])

sfn_client = boto3.client("stepfunctions")
STATE_MACHINE_ARN = os.environ["STATE_MACHINE_ARN"]


def _response(status, body):
    return {
        "statusCode": status,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type",
        },
        "body": json.dumps(body),
    }


def handler(event, context):
    # HTTP API v2.0
    method = event["requestContext"]["http"]["method"]
    raw_path = event["rawPath"]

    if method == "OPTIONS":
        return _response(200, {"ok": True})

    body = {}
    if event.get("body"):
        try:
            body = json.loads(event["body"])
        except json.JSONDecodeError:
            return _response(400, {"error": "Invalid JSON body"})

    # Routing
    if method == "POST" and raw_path == "/projects":
        return create_project(body)

    if method == "GET" and raw_path == "/projects":
        return list_projects()

    # /projects/{projectId}
    if raw_path.startswith("/projects/"):
        parts = raw_path.strip("/").split("/")
        if len(parts) == 2:
            project_id = parts[1]
            if method == "GET":
                return get_project(project_id)
        if len(parts) == 3 and parts[2] == "start" and method == "POST":
            project_id = parts[1]
            return start_cutover(project_id)

    return _response(404, {"error": f"No route for {method} {raw_path}"})


def create_project(payload):
    name = payload.get("name")
    project_type = payload.get("type", "generic")
    pattern = payload.get("pattern", "standard")

    if not name:
        return _response(400, {"error": "Missing 'name'"})

    project_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()

    item = {
        "projectId": project_id,
        "name": name,
        "type": project_type,
        "pattern": pattern,
        "status": "REGISTERED",
        "createdAt": now,
        "updatedAt": now,
        "steps": {
            "precheck": "PENDING",
            "execute": "PENDING",
            "validate": "PENDING",
        },
    }

    table.put_item(Item=item)

    return _response(201, {"projectId": project_id, "project": item})


def list_projects():
    resp = table.scan(Limit=50)
    items = resp.get("Items", [])
    return _response(200, {"projects": items})


def get_project(project_id):
    resp = table.get_item(Key={"projectId": project_id})
    item = resp.get("Item")
    if not item:
        return _response(404, {"error": "Project not found"})
    return _response(200, item)


def start_cutover(project_id):
    # Ensure project exists
    resp = table.get_item(Key={"projectId": project_id})
    item = resp.get("Item")
    if not item:
        return _response(404, {"error": "Project not found"})

    # Update status to SCHEDULED
    now = datetime.now(timezone.utc).isoformat()
    table.update_item(
        Key={"projectId": project_id},
        UpdateExpression="SET #s = :s, updatedAt = :t",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={":s": "SCHEDULED", ":t": now},
    )

    # Start state machine
    execution_input = {"projectId": project_id}
    exec_resp = sfn_client.start_execution(
        stateMachineArn=STATE_MACHINE_ARN,
        input=json.dumps(execution_input),
    )

    return _response(
        200,
        {
            "message": "Cutover started",
            "executionArn": exec_resp["executionArn"],
            "projectId": project_id,
        },
    )
