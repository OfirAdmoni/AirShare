import 'package:flutter/material.dart';

/// 3-screen skippable onboarding shown only on first launch.
/// The caller persists the completion flag via [onComplete].
class OnboardingPage extends StatefulWidget {
  const OnboardingPage({required this.onComplete, super.key});

  final VoidCallback onComplete;

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  final PageController _controller = PageController();
  int _currentPage = 0;

  // ── Slide definitions ──────────────────────────────────────────────────────

  static const _slides = [
    _Slide(
      icon: Icons.wifi_tethering_rounded,
      title: 'Air it, Share it',
      body: 'The fastest way to drop files to anyone nearby — '
          'no internet, no accounts, no cloud. '
          'Just open the app and go.',
    ),
    _Slide(
      icon: Icons.wifi_tethering,
      title: 'Open a Room & Broadcast',
      body: 'Host a room and start sharing in seconds.\n\n'
          'Every room is completely temporary — '
          'all files are permanently wiped the moment '
          'the room closes or the app shuts down.',
    ),
    _Slide(
      icon: Icons.sensors,
      title: 'Connect to a Friend',
      body: 'Joining a nearby room is effortless. '
          'Browse shared files in a beautiful grid '
          'and download exactly what you need in a snap.',
    ),
  ];

  // ── Navigation ─────────────────────────────────────────────────────────────

  void _next() {
    if (_currentPage < _slides.length - 1) {
      _controller.nextPage(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    } else {
      widget.onComplete();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isLast = _currentPage == _slides.length - 1;

    return Scaffold(
      backgroundColor: const Color(0xFFDBEAFE),
      body: SafeArea(
        child: Column(
          children: [
            // ── Top bar — Skip ───────────────────────────────────────────────
            SizedBox(
              height: 52,
              child: Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: AnimatedOpacity(
                    opacity: isLast ? 0 : 1,
                    duration: const Duration(milliseconds: 200),
                    child: TextButton(
                      style: TextButton.styleFrom(
                        foregroundColor: const Color(0xFF0A2463),
                      ),
                      onPressed: isLast ? null : widget.onComplete,
                      child: const Text(
                        'Skip',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // ── Slides ───────────────────────────────────────────────────────
            Expanded(
              child: PageView.builder(
                controller: _controller,
                itemCount: _slides.length,
                onPageChanged: (i) => setState(() => _currentPage = i),
                itemBuilder: (_, i) => _SlideView(slide: _slides[i]),
              ),
            ),

            // ── Bottom bar — dots + button ───────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 40),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Dot indicators
                  Row(
                    children: List.generate(_slides.length, (i) {
                      final active = i == _currentPage;
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeOutCubic,
                        margin: const EdgeInsets.only(right: 6),
                        width: active ? 24 : 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: active
                              ? const Color(0xFF0A2463)
                              : const Color(0xFF0A2463).withValues(alpha: 0.25),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      );
                    }),
                  ),

                  // Next / Get Started button
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF2563EB),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 28, vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      textStyle: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                    onPressed: _next,
                    child: Text(isLast ? 'Get Started' : 'Next'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Data model ────────────────────────────────────────────────────────────────

class _Slide {
  const _Slide({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;
}

// ── Slide renderer ────────────────────────────────────────────────────────────

class _SlideView extends StatelessWidget {
  const _SlideView({required this.slide});

  final _Slide slide;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 36),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Icon circle
          Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              color: const Color(0xFF0A2463).withValues(alpha: 0.08),
              shape: BoxShape.circle,
              border: Border.all(
                color: const Color(0xFF0A2463).withValues(alpha: 0.15),
                width: 1.5,
              ),
            ),
            child: Icon(
              slide.icon,
              size: 58,
              color: const Color(0xFF0A2463),
            ),
          ),

          const SizedBox(height: 40),

          // Title
          Text(
            slide.title,
            textAlign: TextAlign.center,
            style: tt.headlineMedium?.copyWith(
              color: const Color(0xFF0A2463),
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3,
              height: 1.2,
            ),
          ),

          const SizedBox(height: 20),

          // Body
          Text(
            slide.body,
            textAlign: TextAlign.center,
            style: tt.bodyLarge?.copyWith(
              color: const Color(0xFF1E3A8A),
              height: 1.65,
            ),
          ),
        ],
      ),
    );
  }
}
