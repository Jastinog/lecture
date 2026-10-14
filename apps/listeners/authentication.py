import hmac

from rest_framework import authentication, exceptions

from .models import Listener, hash_token


class ListenerTokenAuthentication(authentication.BaseAuthentication):
    """`Authorization: Token <token>`: the listener it was issued to, as
    `request.user`. No header passes through as anonymous; a token the server
    doesn't know is a 401, so the app registers again."""

    keyword = "Token"

    def authenticate(self, request):
        parts = authentication.get_authorization_header(request).split()
        if not parts or parts[0].lower() != self.keyword.lower().encode():
            return None
        if len(parts) != 2:
            raise exceptions.AuthenticationFailed("Malformed token header.")
        try:
            token = parts[1].decode()
        except UnicodeError:
            raise exceptions.AuthenticationFailed("Malformed token header.")
        digest = hash_token(token)
        listener = Listener.objects.filter(token_hash=digest).first()
        if listener is None or not hmac.compare_digest(listener.token_hash, digest):
            raise exceptions.AuthenticationFailed("Unknown token.")
        listener.touch()
        return listener, token

    def authenticate_header(self, request):
        return self.keyword
