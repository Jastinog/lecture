from datetime import datetime, timezone
from typing import Any, Dict

from ..base import BaseEventHandler


class SystemHandler(BaseEventHandler):
    """System event handler for ping-pong"""

    async def handle(self, event_data: Dict[str, Any]):
        """Handle system event"""
        event_type = event_data.get("type")

        if event_type == "ping":
            await self._handle_ping()

    async def _handle_ping(self):
        """Handle ping request and respond with pong"""
        await self.send_to_user(
            "pong", {"timestamp": datetime.now(timezone.utc).isoformat()}
        )
