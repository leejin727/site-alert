from pathlib import Path

from dotenv import load_dotenv

# notice/.env의 값(GEMINI_API_KEY 등)을 환경변수로 불러옴. 터미널에서 export한 값이 있으면 그쪽이 우선
load_dotenv(Path(__file__).resolve().parent.parent / ".env")
