from django.urls import path
from . import consumers

websocket_urlpatterns = [
    path('ws/signal/', consumers.SignalingConsumer.as_asgi()),
]
