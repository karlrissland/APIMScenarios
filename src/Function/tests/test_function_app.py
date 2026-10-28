import json
import unittest
from unittest.mock import patch

import azure.functions as func

from function_app import app, hello


class HelloTests(unittest.TestCase):
    def test_environment_and_query_parameter(self):
        request = func.HttpRequest(
            method="GET", url="/api/hello", params={"name": 'Test "user"'}, body=b""
        )
        with patch.dict("os.environ", {"DEMO_ENVIRONMENT": "test"}):
            response = hello.build().get_user_function()(request)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.mimetype, "application/json")
        self.assertEqual(
            json.loads(response.get_body()),
            {"message": 'Hello, Test "user"!', "environment": "test"},
        )

    def test_local_defaults(self):
        request = func.HttpRequest(method="GET", url="/api/hello", body=b"")
        with patch.dict("os.environ", {}, clear=True):
            response = hello.build().get_user_function()(request)
        self.assertEqual(
            json.loads(response.get_body()),
            {"message": "Hello, World!", "environment": "local"},
        )

    def test_route_requires_function_key(self):
        functions = app.get_functions()
        self.assertEqual(len(functions), 1)
        bindings = json.loads(functions[0].get_function_json())["bindings"]
        trigger = next(binding for binding in bindings if binding["type"] == "httpTrigger")
        self.assertEqual(trigger["authLevel"].lower(), func.AuthLevel.FUNCTION.value)
        self.assertEqual(trigger["route"], "hello")
        self.assertEqual(trigger["methods"], ["GET"])