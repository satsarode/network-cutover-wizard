import os
from datetime import datetime, timezone
import boto3

dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["PROJECTS_TABLE"])


def handler(event, context):
    """
    Event from Step Functions:
    {
      "step": "precheck" | "execute" | "validate",
      "projectId": "..."
    }
    """
    step = event.get("step")
    project_id = event.get("projectId")
    if not step or not project_id:
        raise ValueError("Missing step or projectId")

    if step == "precheck":
        return do_precheck(project_id)
    elif step == "execute":
        return do_execute(project_id)
    elif step == "validate":
        return do_validate(project_id)
    else:
        raise ValueError(f"Unknown step {step}")


def _update_step(project_id, step, step_status, overall_status=None, extra_attrs=None):
    now = datetime.now(timezone.utc).isoformat()
    update_expressions = []
    expr_attr_names = {"#steps": "steps"}
    expr_attr_values = {":t": now}

    update_expressions.append("updatedAt = :t")
    update_expressions.append(f"#steps.#s = :stepStatus")
    expr_attr_names["#s"] = step
    expr_attr_values[":stepStatus"] = step_status

    if overall_status:
        update_expressions.append("#status = :overallStatus")
        expr_attr_names["#status"] = "status"
        expr_attr_values[":overallStatus"] = overall_status

    if extra_attrs:
        for k, v in extra_attrs.items():
            placeholder_name = f"#attr_{k}"
            placeholder_value = f":val_{k}"
            expr_attr_names[placeholder_name] = k
            expr_attr_values[placeholder_value] = v
            update_expressions.append(f"{placeholder_name} = {placeholder_value}")

    table.update_item(
        Key={"projectId": project_id},
        UpdateExpression="SET " + ", ".join(update_expressions),
        ExpressionAttributeNames=expr_attr_names,
        ExpressionAttributeValues=expr_attr_values,
    )


def do_precheck(project_id):
    # Here you'd call out to other Lambdas, VPC checks, etc.
    # MVP: mark precheck as OK
    _update_step(
        project_id,
        step="precheck",
        step_status="OK",
        overall_status="PRECHECK_COMPLETE",
        extra_attrs={"precheckSummary": "Connectivity, routes, VPN, firewalls look healthy (simulated)."},
    )
    return {"projectId": project_id, "step": "precheck", "result": "OK"}


def do_execute(project_id):
    # Here you'd orchestrate Terraform, Lambda, etc. to do the cutover
    # MVP: simulate successful execution
    _update_step(
        project_id,
        step="execute",
        step_status="OK",
        overall_status="IN_PROGRESS",
        extra_attrs={"executionSummary": "Network pattern applied (simulated Lambda/Terraform)."},
    )
    return {"projectId": project_id, "step": "execute", "result": "OK"}


def do_validate(project_id):
    # Here you'd run post-cutover validation (connectivity, routes, firewalls)
    # MVP: simulate successful validation
    _update_step(
        project_id,
        step="validate",
        step_status="OK",
        overall_status="SUCCESS",
        extra_attrs={"validationSummary": "Post-cutover checks passed (simulated)."},
    )
    return {"projectId": project_id, "step": "validate", "result": "OK"}
