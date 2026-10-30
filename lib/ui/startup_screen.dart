import 'package:dogcodes_app/l10n/strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Matches the native launch artwork. No artificial minimum display duration.
class StartupScreen extends StatefulWidget {
  const StartupScreen({super.key});

  @override
  State<StartupScreen> createState() => _StartupScreenState();
}

class _StartupScreenState extends State<StartupScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );
  late final Animation<double> _opacity = Tween(
    begin: 0.35,
    end: 1.0,
  ).animate(CurvedAnimation(parent: _breath, curve: Curves.easeInOut));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _breath.stop();
      _breath.value = 1;
    } else if (!_breath.isAnimating) {
      _breath.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.black,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
      child: ColoredBox(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            const Center(
              child: Image(
                image: AssetImage('assets/branding/launch-lockup.png'),
                width: 240,
                height: 240,
                semanticLabel: 'dog.codes',
                filterQuality: FilterQuality.high,
              ),
            ),
            Positioned(
              left: 24,
              right: 24,
              bottom: MediaQuery.paddingOf(context).bottom + 32,
              child: Semantics(
                label: tr("正在准备工作区"),
                liveRegion: true,
                child: ExcludeSemantics(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      FadeTransition(
                        opacity: _opacity,
                        child: Container(
                          width: 5,
                          height: 5,
                          decoration: const BoxDecoration(
                            color: Color(0xFFB7F34C),
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                      const SizedBox(width: 9),
                      Text(
                        tr("正在准备工作区"),
                        style: TextStyle(
                          color: Color(0xFF858585),
                          fontSize: 12,
                          fontWeight: FontWeight.w400,
                          letterSpacing: 0.8,
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
