#!/bin/sh
# Flutter 웹을 빌드해 서버가 제공하는 폴더(serve/web)로 복사. 배포 서버에는 Flutter가 없어 결과물을 커밋함.
# 사용법: ./build_web.sh  (그다음 serve/web 변경을 커밋)
set -e
cd "$(dirname "$0")/site_alert"
# 화면 엔진(canvaskit)을 구글 CDN이 아니라 같은 서버에서 받도록 빌드에 포함
flutter build web --release --no-web-resources-cdn
rm -rf ../serve/web
cp -R build/web ../serve/web
find ../serve/web -name '*.symbols' -delete  # 오류 추적용 기호 파일. 실행에는 필요 없음
echo "serve/web 갱신 완료"
