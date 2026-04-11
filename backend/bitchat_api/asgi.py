import os

from channels.auth import AuthMiddlewareStack
from channels.routing import ProtocolTypeRouter, URLRouter
from channels.security.websocket import AllowedHostsOriginValidator
from django.core.asgi import get_asgi_application

os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'bitchat_api.settings')

# Import routing AFTER setting DJANGO_SETTINGS_MODULE
from bitchat.routing import websocket_urlpatterns  # noqa: E402

application = ProtocolTypeRouter({
    # Regular HTTP → existing Django views
    'http': get_asgi_application(),

    # WebSocket → signaling consumer
    # AllowedHostsOriginValidator rejects connections from unknown origins
    'websocket': AllowedHostsOriginValidator(
        AuthMiddlewareStack(
            URLRouter(websocket_urlpatterns)
        )
    ),
})
