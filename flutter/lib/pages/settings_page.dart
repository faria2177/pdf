import 'package:material_ui/material_ui.dart';

import '../services/recent_store.dart';
import '../services/theme_controller.dart';
import '../widgets/dialogs.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ValueListenableBuilder<ThemeMode>(
        valueListenable: ThemeController.instance,
        builder: (context, mode, _) => ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            _header(context, 'Appearance'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  for (final (m, icon, label) in const [
                    (ThemeMode.light, Icons.light_mode_outlined, 'Light'),
                    (ThemeMode.dark, Icons.dark_mode_outlined, 'Dark'),
                    (ThemeMode.system, Icons.brightness_auto_outlined, 'System'),
                  ])
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: _ModeCard(
                          icon: icon,
                          label: label,
                          selected: mode == m,
                          preview: m,
                          onTap: () => ThemeController.instance.set(m),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
              child: Text(
                switch (mode) {
                  ThemeMode.light => 'Always light.',
                  ThemeMode.dark => 'Always dark — easier on the eyes at night.',
                  ThemeMode.system => "Follows your phone's dark mode setting.",
                },
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            const SizedBox(height: 8),
            _header(context, 'Storage'),
            ListTile(
              leading: const Icon(Icons.history),
              title: const Text('Clear Recent'),
              subtitle: Text('${RecentStore.instance.items.length} files kept inside the app'),
              onTap: () async {
                if (await confirm(context, 'Delete all files listed in Recent from this app? '
                    'Files you saved to your phone are not affected.', ok: 'Clear')) {
                  await RecentStore.instance.clear();
                  if (context.mounted) toast(context, 'Recent cleared');
                }
              },
            ),
            _header(context, 'About'),
            ListTile(
              leading: Icon(Icons.picture_as_pdf, color: scheme.primary),
              title: const Text('PDF Studio'),
              subtitle: const Text('Offline PDF tools · scanner by DocScanner (doclens) · rendering by PDFium'),
              onTap: () => showAboutDialog(
                context: context,
                applicationName: 'PDF Studio',
                children: const [
                  Text('A private, offline PDF reader, scanner and toolkit. Nothing leaves your phone.'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
        child: Text(
          text.toUpperCase(),
          style: TextStyle(
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.w700,
            fontSize: 12,
            letterSpacing: 0.8,
          ),
        ),
      );
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({
    required this.icon,
    required this.label,
    required this.selected,
    required this.preview,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final ThemeMode preview;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final darkPreview = preview == ThemeMode.dark;
    final bg = darkPreview ? const Color(0xFF1E1E22) : const Color(0xFFF5F5F7);
    final fg = darkPreview ? const Color(0xFF3A3A40) : const Color(0xFFDDDDE2);
    Widget mock(Color b, Color f) => Container(
          decoration: BoxDecoration(color: b, borderRadius: BorderRadius.circular(8)),
          padding: const EdgeInsets.all(6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(height: 6, width: 30, color: scheme.primary),
              const SizedBox(height: 5),
              Container(height: 4, color: f),
              const SizedBox(height: 3),
              Container(height: 4, width: 40, color: f),
              const SizedBox(height: 3),
              Container(height: 4, color: f),
            ],
          ),
        );
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: selected ? scheme.primary : scheme.outlineVariant, width: selected ? 2.5 : 1),
          color: selected ? scheme.primaryContainer.withValues(alpha: 0.35) : null,
        ),
        child: Column(
          children: [
            SizedBox(
              height: 64,
              child: preview == ThemeMode.system
                  ? Row(children: [
                      Expanded(child: mock(const Color(0xFFF5F5F7), const Color(0xFFDDDDE2))),
                      const SizedBox(width: 3),
                      Expanded(child: mock(const Color(0xFF1E1E22), const Color(0xFF3A3A40))),
                    ])
                  : mock(bg, fg),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 18, color: selected ? scheme.primary : null),
                const SizedBox(width: 4),
                Text(label, style: TextStyle(fontWeight: selected ? FontWeight.bold : null)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
