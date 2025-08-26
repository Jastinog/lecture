from typing import Dict, Type

from apps.system.services import Logger

from .base import BaseEventHandler
from .handlers.system import SystemHandler

logger = Logger(app_name="websocket")


class EventDispatcher:
    """Event dispatcher - routes events to appropriate handlers"""

    def __init__(self):
        self.handlers: Dict[str, Type[BaseEventHandler]] = {
            # System events
            "ping": SystemHandler,
        }

    async def dispatch(self, consumer, event_data: Dict) -> bool:
        """Dispatch event to appropriate handler"""
        event_type = event_data.get("type")

        if not event_type:
            await consumer.send_error("VALIDATION_ERROR", "Field 'type' is required")
            return False

        handler_class = self.handlers.get(event_type)
        if not handler_class:
            logger.error(f"Unknown event type: {event_type}")
            logger.error(f"Available handlers: {list(self.handlers.keys())}")
            await consumer.send_error(
                "UNKNOWN_EVENT", f"Unknown event type: {event_type}"
            )
            return False

        try:
            handler = handler_class(consumer, user=None)

            await handler.handle(event_data)
            return True

        except Exception as e:
            logger.error(f"Error processing event {event_type}: {str(e)}")
            await consumer.send_error("PROCESSING_ERROR", "Internal server error")
            return False
