"""Configuration de l'application, lue exclusivement depuis les variables d'environnement.

Principe des « 12-factor apps » : le même artefact (image Docker) tourne dans tous les
environnements ; seule la configuration injectée change (Compose, ConfigMap, Secret).
"""

from functools import lru_cache

from pydantic import SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="", case_sensitive=False)

    app_name: str = "plateforme-api"
    app_version: str = "dev"
    log_level: str = "INFO"

    db_host: str = "localhost"
    db_port: int = 5432
    db_name: str = "plateforme"
    db_user: str = "plateforme"
    # SecretStr : la valeur n'apparaît jamais dans repr(), les logs ou les tracebacks
    db_password: SecretStr = SecretStr("")
    db_pool_min: int = 1
    db_pool_max: int = 5
    db_connect_timeout: int = 3

    def conninfo(self) -> str:
        """Chaîne de connexion libpq. Ne jamais la journaliser : elle contient le mot de passe."""
        return (
            f"host={self.db_host} port={self.db_port} dbname={self.db_name} "
            f"user={self.db_user} password={self.db_password.get_secret_value()} "
            f"connect_timeout={self.db_connect_timeout}"
        )


@lru_cache
def get_settings() -> Settings:
    return Settings()
