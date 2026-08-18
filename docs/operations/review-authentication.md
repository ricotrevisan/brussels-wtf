# Review authentication and recovery

The MVP review interface uses a single encrypted, signed Phoenix cookie session for Rico. Credentials are deployment secrets, not database records: set `REVIEW_USERNAME` and a randomly generated `REVIEW_PASSWORD` of at least 16 characters in Coolify. Production refuses to boot when either value is absent or the password is too short.

`POST /review/session` is protected by Phoenix CSRF verification. A successful login renews the session identifier. Review sessions expire after eight hours and every protected request rechecks both the configured actor ID and a one-way credential version. Cookies are HTTP-only, encrypted, signed, `SameSite=Lax`, and `Secure` in production. Review Ash resources independently require a reviewer actor, so bypassing the router does not authorize reads or actions.

## Recovery and rotation

There is no public registration or email-reset route for the single-editor MVP.

1. Generate a new secret, for example with `openssl rand -base64 32`.
2. Replace `REVIEW_PASSWORD` in Coolify and redeploy or restart the application.
3. Sign in with the new value.

Changing the password changes the credential version and immediately invalidates existing review sessions. Changing `SECRET_KEY_BASE` also invalidates every Phoenix session, but should be reserved for signing-key compromise. The username can be rotated with `REVIEW_USERNAME`; existing sessions remain tied to the fixed audited actor ID `rico`.

Private source previews are served by the application only after both reviewer-session authorization and verification of a 60-second Phoenix token. Responses use `Cache-Control: private, no-store`; rustFS object keys, endpoints, and credentials are never rendered into preview URLs.
