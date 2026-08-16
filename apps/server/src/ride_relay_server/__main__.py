import uvicorn

from .config import get_settings


def main() -> None:
    settings = get_settings()
    uvicorn.run(
        "ride_relay_server.app:default_app",
        factory=True,
        host="0.0.0.0",  # noqa: S104
        port=8080,
        proxy_headers=True,
        forwarded_allow_ips=settings.forwarded_allow_ips,
    )


if __name__ == "__main__":
    main()
