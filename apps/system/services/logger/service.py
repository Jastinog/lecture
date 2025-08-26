# -*- coding: utf-8 -*-
import decimal
import glob
import inspect
import json
import os
from collections.abc import Mapping
from datetime import date, datetime
from typing import Any, Dict, Optional


class LogFileManager:
    """
    Manages log file operations including rotation, backup and file handling.
    """

    def __init__(
        self,
        log_dir: str = "logs",
        app_name: str = "System",
        master_file: str = "logs/master.log",
        max_file_size_mb: float = 1,
        max_backup_count: int = 5,
    ):
        self.app_name = app_name
        self.log_dir = f"{log_dir}/{self.app_name}"
        self.master_file = master_file
        self.max_file_size_bytes = max_file_size_mb * 1024 * 1024
        self.max_backup_count = max_backup_count

        self._ensure_log_directory()

    def _ensure_log_directory(self) -> None:
        """Ensures the log directory exists."""
        if not os.path.exists(self.log_dir):
            os.makedirs(self.log_dir)

    def _remove_old_backups(self, backup_files: list) -> None:
        """Removes old backup files when the count exceeds max_backup_count."""
        while len(backup_files) >= self.max_backup_count:
            try:
                oldest_file = backup_files.pop(0)
                if os.path.exists(oldest_file):
                    os.remove(oldest_file)
            except OSError:
                continue

    def _create_backup_file(self, file_path: str) -> str:
        """Creates a backup file with timestamp."""
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        return f"{os.path.splitext(file_path)[0]}.{timestamp}.log"

    def check_and_rotate_file(self, file_path: str) -> str:
        """
        Checks if file needs rotation and rotates if necessary.

        Args:
            file_path: Path to the log file to check

        Returns:
            str: Path to the current log file
        """
        if not os.path.exists(file_path):
            return file_path

        try:
            # Check if file size exceeds the limit
            if os.path.getsize(file_path) >= self.max_file_size_bytes:
                # Get existing backup files
                backup_files = sorted(
                    glob.glob(f"{os.path.splitext(file_path)[0]}.*.log")
                )

                # Remove old backups if needed
                self._remove_old_backups(backup_files)

                # Create new backup file
                backup_path = self._create_backup_file(file_path)

                # Rotate the current file
                try:
                    if os.path.exists(file_path):
                        os.rename(file_path, backup_path)
                except OSError:
                    pass  # Continue even if rotation fails

        except Exception:
            pass  # Ensure the method always returns a file path

        return file_path

    def write_log(self, file_path: str, content: str) -> bool:
        """
        Writes content to the specified log file.

        Args:
            file_path: Path to the log file
            content: Content to write

        Returns:
            bool: True if writing was successful, False otherwise
        """
        try:
            with open(file_path, "a", encoding="utf-8") as f:
                f.write(content)
            return True
        except Exception:
            return False

    def get_log_file_path(self, file_name: str, level: str) -> str:
        """
        Generates the full path for a log file.

        Args:
            file_name: Base name of the file
            level: Log level

        Returns:
            str: Full path to the log file
        """
        return os.path.join(self.log_dir, f"{file_name}.{level.lower()}")


class DataFormatter:
    """
    Simple data formatter that prettifies JSON-like objects and handles basic types.
    """

    def __init__(self):
        self.indent = 4  # Standard JSON indentation

    def _json_serial(self, obj: Any) -> str:
        """JSON serializer for non-standard types."""
        if isinstance(obj, (datetime, date)):
            return obj.isoformat()
        if isinstance(obj, decimal.Decimal):
            return str(obj)
        if isinstance(obj, set):
            return list(obj)
        if hasattr(obj, "__dict__"):
            return obj.__dict__
        return str(obj)

    def format_value(self, value: Any) -> str:
        """
        Format a value based on its type.
        Primarily focuses on proper JSON formatting for dict-like objects.
        """
        try:
            # For dictionaries and objects with __dict__
            if isinstance(value, Mapping) or hasattr(value, "__dict__"):
                if hasattr(value, "__dict__"):
                    value = value.__dict__
                return json.dumps(
                    value,
                    indent=self.indent,
                    ensure_ascii=False,
                    default=self._json_serial,
                )

            # For lists and tuples, only if they contain dictionaries
            if isinstance(value, (list, tuple)):
                # Check if the list contains dictionaries
                if any(isinstance(item, (dict, Mapping)) for item in value):
                    return json.dumps(
                        value,
                        indent=self.indent,
                        ensure_ascii=False,
                        default=self._json_serial,
                    )
                return str(value)

            # For all other types, just return string representation
            return str(value)

        except Exception:
            return str(value)

    def format_message(self, message: Any) -> str:
        """Format a message for logging."""
        return self.format_value(message)


class MessageFormatter:
    """
    Handles message formatting for logging with service information consolidated at the top.
    """

    def __init__(self, use_console_icons: bool = False):
        self.use_console_icons = use_console_icons

        self.LEVEL_ICONS = {
            "ERROR": ("❌", "!") if not use_console_icons else ("✘", "!"),
            "INFO": ("ℹ️", "i") if not use_console_icons else ("i", "i"),
            "DEBUG": ("🔧", "D") if not use_console_icons else ("D", "D"),
            "WARNING": ("⚠️", "W") if not use_console_icons else ("‼", "W"),
            "CRITICAL": ("🚨", "C") if not use_console_icons else ("!!", "C"),
            "SUCCESS": ("✅", "+") if not use_console_icons else ("√", "+"),
            "SYSTEM": ("⚙️", "S") if not use_console_icons else ("§", "S"),
        }

        self.data_formatter = DataFormatter()
        self.MESSAGE_SEPARATOR = "=" * 40
        self.VALUE_SEPARATOR = "-" * 40

    def _format_service_info(self, timestamp: str, level: str, call_info: dict) -> str:
        """Format all service information in the header."""
        icon, fallback = self.LEVEL_ICONS.get(level, ("📝", "L"))
        return (
            f"{self.MESSAGE_SEPARATOR}\n"
            f"Time: {timestamp} | Level: {icon} {level:<7}\n"
            f"Source: {call_info.get('file', 'unknown')} | "
            f"Line: {call_info.get('line', 'unknown')} | "
            f"Function: {call_info.get('function', 'unknown')}\n"
            f"{self.MESSAGE_SEPARATOR}"
        )

    def format_log_entry(self, messages: tuple, level: str, call_info: dict) -> str:
        """
        Format a log entry with service info at top and clean message content below.
        """
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]

        # Format service information header
        header = self._format_service_info(timestamp, level, call_info)

        # Format message content
        content_lines = []
        for i, msg in enumerate(messages):
            formatted_msg = self.data_formatter.format_message(msg)

            # Add separator between values if needed
            if i > 0:
                content_lines.append(self.VALUE_SEPARATOR)

            # Handle multiline values without prefixes
            content_lines.extend(formatted_msg.split("\n"))

        # Combine header and content
        parts = [header, *content_lines, self.MESSAGE_SEPARATOR]

        return "\n".join(parts) + "\n"

    def format_slack_message(self, messages: tuple, level: str, call_info: dict) -> str:
        """
        Format Slack message with consolidated service information.
        """
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        icon, _ = self.LEVEL_ICONS.get(level, ("📝", "L"))

        # Service info header in two lines
        header = (
            f"{icon} *{level}* | {timestamp}\n"
            f"Source: {call_info.get('file', 'unknown')} | "
            f"Line: {call_info.get('line', 'unknown')} | "
            f"Function: {call_info.get('function', 'unknown')}"
        )

        # Content
        content_parts = []
        for i, msg in enumerate(messages):
            formatted_msg = self.data_formatter.format_message(msg)
            if i > 0:
                content_parts.append("---")
            if "\n" in formatted_msg:
                content_parts.append(f"```{formatted_msg}```")
            else:
                content_parts.append(formatted_msg)

        content = "\n".join(content_parts)

        return f"{header}\n\n{content}"


class Logger:
    def __init__(
        self,
        log_dir: str = "logs",
        app_name: str = "System",
        master_file: str = "logs/master.log",
        max_file_size_mb: float = 1,
        max_backup_count: int = 5,
        use_console_icons: bool = False,
    ) -> None:
        self.file_manager = LogFileManager(
            log_dir=log_dir,
            app_name=app_name,
            master_file=master_file,
            max_file_size_mb=max_file_size_mb,
            max_backup_count=max_backup_count,
        )
        self.formatter = MessageFormatter(use_console_icons)

    def _get_caller_info(self, stack_level: int = 2) -> Dict[str, Any]:
        """
        Get information about the caller of the logging function.

        Args:
            stack_level: How many levels up in the stack to look.
                       2 for direct calls to log(),
                       3 for calls through convenience methods (error, info, etc.)
        """
        try:
            # Get the complete stack
            stack = inspect.stack()

            # Find the first non-logger call
            caller = None
            current_file = __file__  # Path to current logger file

            for frame in stack[1:]:  # Skip first frame (current function)
                if frame.filename != current_file:
                    caller = frame
                    break

            if caller:
                return {
                    "file": os.path.relpath(caller.filename, start=os.getcwd()),
                    "line": caller.lineno,
                    "function": caller.function,
                }

            # Fallback to the specified stack level if we couldn't find a non-logger call
            caller = stack[stack_level]
            return {
                "file": os.path.relpath(caller.filename, start=os.getcwd()),
                "line": caller.lineno,
                "function": caller.function,
            }

        except Exception:
            return {
                "file": "unknown_file",
                "line": "unknown_line",
                "function": "unknown_function",
            }

    def log(
        self,
        *messages: Any,
        level: str = "INFO",
        user: Optional[Any] = None,
        master_log: bool = True,
    ) -> None:
        try:
            stack_level = 2 if level == "INFO" else 3
            call_info = self._get_caller_info(stack_level)
            log_content = self.formatter.format_log_entry(messages, level, call_info)

            # Get file name from call info
            file_name = os.path.splitext(
                os.path.basename(call_info.get("file", "unknown"))
            )[0]

            # Get log file path and handle rotation
            log_file = self.file_manager.get_log_file_path(file_name, level)
            log_file = self.file_manager.check_and_rotate_file(log_file)

            # Write to log file
            self.file_manager.write_log(log_file, log_content)

            # Handle master log if needed
            if master_log:
                master_file = self.file_manager.check_and_rotate_file(
                    self.file_manager.master_file
                )
                self.file_manager.write_log(master_file, f"{log_content}\n\n")

            if user:
                try:
                    self.log_to_db(user, self.formatter.format_content(messages), level)
                except Exception:
                    pass

        except Exception:
            pass

    def error(
        self,
        *messages: Any,
        user: Optional[Any] = None,
        master_log: bool = True,
    ) -> None:
        """Log error level message."""
        self.log(
            *messages,
            level="ERROR",
            user=user,
            master_log=master_log,
        )

    def info(
        self,
        *messages: Any,
        user: Optional[Any] = None,
        master_log: bool = True,
    ) -> None:
        """Log info level message."""
        self.log(
            *messages,
            level="INFO",
            user=user,
            master_log=master_log,
        )

    def debug(
        self,
        *messages: Any,
        user: Optional[Any] = None,
        master_log: bool = True,
    ) -> None:
        """Log debug level message."""
        self.log(
            *messages,
            level="DEBUG",
            user=user,
            master_log=master_log,
        )

    def warning(
        self,
        *messages: Any,
        user: Optional[Any] = None,
        master_log: bool = True,
    ) -> None:
        """Log warning level message."""
        self.log(
            *messages,
            level="WARNING",
            user=user,
            master_log=master_log,
        )

    def critical(
        self,
        *messages: Any,
        user: Optional[Any] = None,
        master_log: bool = True,
    ) -> None:
        """Log critical level message."""
        self.log(
            *messages,
            level="CRITICAL",
            user=user,
            master_log=master_log,
        )

    def success(
        self,
        *messages: Any,
        user: Optional[Any] = None,
        master_log: bool = True,
    ) -> None:
        """Log success level message."""
        self.log(
            *messages,
            level="SUCCESS",
            user=user,
            master_log=master_log,
        )

    def system(
        self,
        *messages: Any,
        user: Optional[Any] = None,
        master_log: bool = True,
    ) -> None:
        """Log system level message."""
        self.log(
            *messages,
            level="SYSTEM",
            user=user,
            master_log=master_log,
        )
