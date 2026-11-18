import os
from pathlib import Path

from dotenv import load_dotenv

# notice/.env의 값(GEMINI_API_KEY 등)을 환경변수로 불러옴. 터미널에서 export한 값이 있으면 그쪽이 우선
load_dotenv(Path(__file__).resolve().parent.parent / ".env")

# 배포 서버에서만 켜는 보호(문서 끄기, 관리자 키, 할 일 분해 하루 상한)의 스위치. 로컬에서는 비워 둠
PRODUCTION = os.getenv("APP_ENV") == "production"
