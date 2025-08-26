from abc import ABC, abstractmethod
from datetime import datetime, timezone
from typing import Any, Dict, Optional

from apps.system.services import Logger

logger = Logger(app_name="websocket")


class BaseEventHandler(ABC):
    """Base class for event handlers"""

    def __init__(self, consumer, user=None):
        self.consumer = consumer
        self.user = user
        self.channel_layer = consumer.channel_layer
        self.room_group_name = consumer.room_group_name

    @abstractmethod
    async def handle(self, event_data: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        """Handle event and return response"""
        pass

    async def send_to_user(self, event_type: str, data: Dict[str, Any] = None):
        """Send event to current user"""
        await self.consumer.send_response(event_type, data)

    async def send_to_room(self, event_type: str, data: Dict[str, Any] = None):
        """Send event to all users in room"""
        message = {
            "type": "room_message",
            "event_type": event_type,
            "data": data,
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }
        await self.channel_layer.group_send(self.room_group_name, message)

    async def send_error(self, code: str, message: str):
        """Send error response"""
        await self.consumer.send_error(code, message)
