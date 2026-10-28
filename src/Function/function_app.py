import json
import os

import azure.functions as func

app = func.FunctionApp(http_auth_level=func.AuthLevel.FUNCTION)


@app.route(route="hello", methods=["GET"])
def hello(req: func.HttpRequest) -> func.HttpResponse:
    return func.HttpResponse(
        json.dumps(
            {
                "message": f"Hello, {req.params.get('name', 'World')}!",
                "environment": os.getenv("DEMO_ENVIRONMENT", "local"),
            }
        ),
        mimetype="application/json",
    )