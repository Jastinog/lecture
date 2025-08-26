import json
import traceback
from datetime import datetime, timezone

from channels.generic.websocket import AsyncWebsocketConsumer

from apps.system.services import Logger
from .services.event_dispatcher import EventDispatcher

logger = Logger(app_name="websocket")


class WebSocketConsumer(AsyncWebsocketConsumer):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.event_dispatcher = EventDispatcher()

    async def connect(self):
        # Simple shared channel for all connections
        self.room_group_name = "camera-control"

        try:
            await self.channel_layer.group_add(self.room_group_name, self.channel_name)
            await self.accept()

            # Send connection confirmation
            await self.send_response(
                "connected", {"message": "Camera control connected"}
            )

        except Exception:
            logger.error(traceback.format_exc())

    async def disconnect(self, close_code):
        if hasattr(self, "room_group_name") and hasattr(self, "channel_name"):
            try:
                await self.channel_layer.group_discard(
                    self.room_group_name, self.channel_name
                )
            except Exception:
                logger.error(traceback.format_exc())

    async def receive(self, text_data):
        try:
            json_data = json.loads(text_data)

            # Check required fields
            if "type" not in json_data:
                await self.send_error("VALIDATION_ERROR", "Field 'type' is required")
                return

            # Add timestamp if missing
            if "timestamp" not in json_data:
                json_data["timestamp"] = datetime.now(timezone.utc).isoformat()

            # Process event through dispatcher
            await self.event_dispatcher.dispatch(self, json_data)

        except json.JSONDecodeError:
            await self.send_error("INVALID_JSON", "Invalid JSON format")
        except Exception:
            logger.error(traceback.format_exc())
            await self.send_error("PROCESSING_ERROR", "Internal server error")

    async def handle_event(self, event_data):
        """Handle incoming events through dispatcher"""
        await self.event_dispatcher.dispatch(self, event_data)

    async def send_response(self, event_type, data=None, error=None):
        """Send response in standard format"""
        try:
            response = {
                "type": event_type,
                "timestamp": datetime.now(timezone.utc).isoformat(),
            }

            if data is not None:
                response["data"] = data

            if error is not None:
                response["error"] = error

            await self.send(text_data=json.dumps(response))

        except Exception:
            logger.error(traceback.format_exc())

    async def send_error(self, error_code, message):
        """Send error response"""
        await self.send_response(
            "error", error={"code": error_code, "message": message}
        )

    async def room_message(self, event):
        """Handle room messages from group"""
        await self.send_response(
            event["event_type"], data=event.get("data"), error=event.get("error")
        )
