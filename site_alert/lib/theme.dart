import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 앱에서 쓰는 색. 화면 파일에는 색 값을 직접 적지 않고 이 이름(또는 테마)을 씀.
abstract final class AppColors {
  static const background = Color(0xFFEEE7DF); // 화면 바탕, 위쪽 제목 줄
  static const card = Color(0xFFFAF7F3); // 카드. 진한 바탕 위에서는 글자색
  static const navy = Color(0xFF22283D); // 글자, 화면마다 가장 중요한 요약 카드, 체크
  static const buttonNavy = Color(0xFF3A486A); // 주 버튼
  static const tan = Color(0xFFB89878); // 선·작은 표시. 밝은 바탕 위 글자로는 흐려서 쓰지 않음
  static const lightTan = Color(0xFFE5D6C4); // 주의를 끌 칩, '확인 필요'
  static const blueGrey = Color(0xFFD9DEE9); // 중립 칩
  static const tabBand = Color(0xFFE3D9D0); // 아래 탭 바
  static const brown = Color(0xFF5A4632); // 연한 황갈색 위의 글자
  static const mutedNavy = Color(0xB322283D); // 흐린 글자. 이보다 흐리면 읽기 어려움
}

ThemeData buildAppTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: AppColors.buttonNavy).copyWith(
    primary: AppColors.buttonNavy,
    onPrimary: AppColors.card,
    primaryContainer: AppColors.navy,
    onPrimaryContainer: AppColors.card,
    secondary: AppColors.buttonNavy,
    onSecondary: AppColors.card,
    secondaryContainer: AppColors.blueGrey,
    onSecondaryContainer: AppColors.navy,
    tertiary: AppColors.tan,
    onTertiary: AppColors.navy,
    tertiaryContainer: AppColors.lightTan,
    onTertiaryContainer: AppColors.brown,
    surface: AppColors.background,
    onSurface: AppColors.navy,
    onSurfaceVariant: AppColors.mutedNavy,
    // 대화창·아래 시트·메뉴는 카드와 같은 색
    surfaceContainerLowest: AppColors.card,
    surfaceContainerLow: AppColors.card,
    surfaceContainer: AppColors.card,
    surfaceContainerHigh: AppColors.card,
    surfaceContainerHighest: AppColors.card,
    surfaceTint: Colors.transparent,
    inverseSurface: AppColors.navy,
    onInverseSurface: AppColors.card,
    inversePrimary: AppColors.lightTan,
    outline: AppColors.navy.withValues(alpha: 0.5),
    outlineVariant: AppColors.navy.withValues(alpha: 0.15),
    shadow: AppColors.navy,
  );
  return ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.background,
    // 웹은 한글 폰트가 없어 실행 중에 내려받으므로 내장 폰트를 씀. 휴대폰은 기기 기본 폰트 그대로.
    fontFamily: kIsWeb ? 'GowunDodum' : null,
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.background,
      foregroundColor: AppColors.navy,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      // 웹은 본문을 가운데로 모으므로 제목도 버튼 수와 상관없이 가운데에 둠
      centerTitle: kIsWeb ? true : null,
    ),
    // 바탕과 카드의 밝기 차이가 작아서 옅은 그림자로 경계를 보탬
    cardTheme: CardThemeData(
      color: AppColors.card,
      surfaceTintColor: Colors.transparent,
      shadowColor: AppColors.navy.withValues(alpha: 0.35),
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (states) =>
            states.contains(WidgetState.selected) &&
                !states.contains(WidgetState.disabled)
            ? AppColors.navy
            : null,
      ),
      checkColor: const WidgetStatePropertyAll(AppColors.card),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: AppColors.navy,
      linearTrackColor: AppColors.blueGrey,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? AppColors.navy : null,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? AppColors.card
              : AppColors.navy,
        ),
      ),
    ),
  );
}
