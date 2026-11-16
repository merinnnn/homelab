#!/usr/bin/env python3
"""Request-path regressions; no Home Assistant connection or private data."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import MagicMock, patch

script = Path(__file__).with_name('verify-home-assistant.py')
if not script.is_file():
    script = Path(__file__).resolve().parent.parent/'deploy/verify-home-assistant.py'
spec = importlib.util.spec_from_file_location('ha_verifier', script)
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


class RequestTests(unittest.TestCase):
    def response(self, status, headers, body):
        connection = MagicMock()
        response = connection.getresponse.return_value
        response.status = status
        response.getheaders.return_value = headers
        response.read.return_value = body
        return connection

    def test_http_redirect_request_preserves_host_and_closes(self):
        connection = self.response(308, [('Location', 'https://ha.home.arpa/')], b'')
        with patch.object(verifier.http.client, 'HTTPConnection', return_value=connection) as constructor:
            status, headers, body = verifier.get(None, '/', plain_http=True)
        constructor.assert_called_once_with('192.168.1.58', 80, timeout=30)
        connection.request.assert_called_once_with('GET', '/', headers={'Host': 'ha.home.arpa'})
        connection.close.assert_called_once()
        self.assertEqual(status, 308)
        self.assertEqual(headers['location'], 'https://ha.home.arpa/')
        self.assertEqual(body, b'')

    def test_https_frontend_uses_validating_transport_and_closes(self):
        connection = self.response(200, [('Content-Type', 'text/html')], b'<home-assistant>')
        context = object()
        with patch.object(verifier, 'HTTPS', return_value=connection) as constructor:
            status, headers, body = verifier.get(context, '/')
        constructor.assert_called_once_with(context)
        self.assertEqual(status, 200)
        self.assertEqual(headers['content-type'], 'text/html')
        self.assertIn(b'home-assistant', body)
        connection.close.assert_called_once()

    def test_authenticated_api_sends_token_only_in_authorization_header(self):
        connection = self.response(200, [], b'{}')
        with patch.object(verifier, 'HTTPS', return_value=connection):
            verifier.get(None, '/api/config', token='synthetic-test-token')
        connection.request.assert_called_once_with('GET', '/api/config', headers={
            'Host': 'ha.home.arpa', 'Authorization': 'Bearer synthetic-test-token'})
        connection.close.assert_called_once()


if __name__ == '__main__':
    unittest.main()
