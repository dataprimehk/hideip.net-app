/// The pieces of the 1.2.1 Account screen, top to bottom: the status card,
/// the device meter, the number with its two small actions, the folded
/// rare actions, and the Add a device sheet.
library;

import 'package:flutter/material.dart';

import '../../../core/account_number.dart';
import '../../../core/haptics.dart';
import '../../brand.dart';
import '../../strings.dart';
import '../hip.dart';
import '../hip_sheet.dart';

/// A sentence with [mono] set in the number face and the rest in [words].
/// A date inside a line is a number, wherever a translation moves it.
InlineSpan monoIn(String line, String mono, TextStyle words, TextStyle nums) {
  final at = mono.isEmpty ? -1 : line.indexOf(mono);
  if (at < 0) return TextSpan(text: line, style: words);
  return TextSpan(
    children: [
      if (at > 0) TextSpan(text: line.substring(0, at), style: words),
      TextSpan(text: mono, style: nums),
      if (at + mono.length < line.length)
        TextSpan(text: line.substring(at + mono.length), style: words),
    ],
  );
}

/// How the account stands, by color: on, needs something, or broken.
enum StatusTone { on, off, bad }

/// The first thing on the screen: does Premium work, and until when. The
/// one action the state asks for lives inside it.
class AccountStatusCard extends StatelessWidget {
  final StatusTone tone;
  final String title;

  /// The line under the title, with [lineMono] (a date) in mono.
  final String? line;
  final String lineMono;
  final String? fine;
  final List<Widget> actions;

  const AccountStatusCard({
    super.key,
    required this.tone,
    required this.title,
    this.line,
    this.lineMono = '',
    this.fine,
    this.actions = const [],
  });

  Color get _hue => switch (tone) {
    StatusTone.on => Hip.success,
    StatusTone.off => Hip.warning,
    StatusTone.bad => Hip.danger,
  };

  (double, double, double) get _hsl => switch (tone) {
    StatusTone.on => (152, 60, 46),
    StatusTone.off => (35, 90, 50),
    StatusTone.bad => (4, 72, 50),
  };

  @override
  Widget build(BuildContext context) {
    final (h, s, l) = _hsl;
    final wash = Hip.dm ? .14 : .10;
    final words = Hip.sans(400, 14, color: Hip.inkSoft, height: 1.45);
    final nums = Hip.mono(600, 13, color: Hip.ink, height: 1.45);
    final line = this.line;
    return Semantics(
      container: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
        decoration: BoxDecoration(
          border: Border.all(color: Brand.hsl(h, s, l, .38), width: 1.5),
          borderRadius: BorderRadius.circular(Hip.radius),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: const [0, .7],
            colors: [
              Color.alphaBlend(Brand.hsl(h, s, l, wash), Hip.card),
              Hip.card,
            ],
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: _hue,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Brand.hsl(h, s, l, .18),
                        spreadRadius: 4,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Text(
                    title,
                    style: Hip.sans(
                      750,
                      22,
                      color: Hip.ink,
                      letterSpacing: -.5,
                      height: 1.2,
                    ),
                  ),
                ),
              ],
            ),
            if (line != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text.rich(monoIn(line, lineMono, words, nums)),
              ),
            if (fine != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  fine!,
                  style: Hip.sans(400, 13, color: Hip.muted, height: 1.45),
                ),
              ),
            for (final a in actions)
              Padding(padding: const EdgeInsets.only(top: 12), child: a),
          ],
        ),
      ),
    );
  }
}

/// The screen's own call to action: [HipCta]'s look, but the label wraps
/// onto a second line instead of running off the button with large text or
/// on a narrow screen ("Sign in with another number" at twice the size).
class AccountCta extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final bool connect;
  final bool ghost;
  final bool quiet;

  /// A red-tinted ghost, for signing out and deleting.
  final bool danger;
  const AccountCta(
    this.label, {
    super.key,
    this.onTap,
    this.connect = false,
    this.ghost = false,
    this.quiet = false,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    final fg = connect
        ? Colors.white
        : danger
        ? Brand.hsl(4, 68, 50)
        : ghost
        ? Hip.ink
        : quiet
        ? Hip.muted
        : Colors.white;
    final bg = connect
        ? Hip.blue
        : danger
        ? Brand.hsl(4, 80, 60, .08)
        : ghost
        ? (Hip.dm ? Brand.hsl(222, 14, 16) : Hip.line2)
        : quiet
        ? Colors.transparent
        : Hip.blue;
    final button = Container(
      constraints: BoxConstraints(minHeight: quiet ? 44 : 54),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
        border: connect
            ? Border.all(color: Brand.hsl(220, 95, 72, .8), width: 1.5)
            : danger
            ? Border.all(color: Brand.hsl(4, 80, 60, .35), width: 1.5)
            : null,
        boxShadow: connect
            ? [
                BoxShadow(
                  color: Brand.hsl(220, 95, 55, .55),
                  blurRadius: 26,
                  offset: const Offset(0, 10),
                  spreadRadius: -12,
                ),
              ]
            : null,
      ),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: Hip.sans(
          quiet ? 550 : 600,
          quiet ? 15 : 16.5,
          color: fg,
          height: 1.25,
        ),
      ),
    );
    return Semantics(
      button: true,
      enabled: !disabled,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: disabled
            ? null
            : () {
                Haptics.tap();
                onTap!();
              },
        child: Opacity(opacity: disabled ? .55 : 1, child: button),
      ),
    );
  }
}

/// A section label with a mono count on the right ("DEVICES   3 of 5").
class CountedSectionLabel extends StatelessWidget {
  final String text;
  final String? count;
  const CountedSectionLabel(this.text, {super.key, this.count});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 22, 14, 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Text(
              text.toUpperCase(),
              style: Hip.sans(
                650,
                Hip.captionSize,
                color: Hip.muted2,
                letterSpacing: .91,
              ),
            ),
          ),
          if (count != null)
            Text(count!, style: Hip.mono(600, 12.5, color: Hip.muted2)),
        ],
      ),
    );
  }
}

/// How many of the account's places are taken: one segment per place, or a
/// plain bar when the limit is too large for segments to read.
class DeviceMeter extends StatelessWidget {
  final int used;
  final int limit;
  const DeviceMeter({super.key, required this.used, required this.limit});

  @override
  Widget build(BuildContext context) {
    final cap = limit <= 0 ? 1 : limit;
    final filled = used.clamp(0, cap);
    return Semantics(
      label: S.accountDevicesCount(used, limit),
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: cap <= 12
            ? Row(
                children: [
                  for (var i = 0; i < cap; i++) ...[
                    if (i > 0) const SizedBox(width: 5),
                    Expanded(child: _bar(i < filled)),
                  ],
                ],
              )
            : ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: filled / cap,
                  minHeight: 5,
                  color: Hip.blue,
                  backgroundColor: Hip.line,
                ),
              ),
      ),
    );
  }

  Widget _bar(bool on) => Container(
    height: 5,
    decoration: BoxDecoration(
      color: on ? Hip.blue : Hip.line,
      borderRadius: BorderRadius.circular(3),
    ),
  );
}

/// A gray (or blue, or red) square in front of a row, as in Settings.
class AccountTile extends StatelessWidget {
  final IconData icon;
  final Color? color;
  final bool blue;
  const AccountTile(this.icon, {super.key, this.color, this.blue = false});

  @override
  Widget build(BuildContext context) => Container(
    width: 38,
    height: 38,
    decoration: BoxDecoration(
      color: blue ? Hip.blueSoft : Hip.line2,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Icon(
      icon,
      size: 19,
      color: color ?? (blue ? Hip.blue : Hip.inkSoft),
    ),
  );
}

/// A row in a [HipListGroup] whose subtitle wraps instead of ending in an
/// ellipsis: these subtitles are sentences that have to be read whole.
class AccountRow extends StatelessWidget {
  final Widget? leading;
  final String title;
  final String? subtitle;
  final Color? titleColor;
  final bool chevron;
  final VoidCallback? onTap;
  const AccountRow({
    super.key,
    this.leading,
    required this.title,
    this.subtitle,
    this.titleColor,
    this.chevron = true,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 12)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Hip.sans(
                    650,
                    Hip.titleSize,
                    color: titleColor ?? Hip.ink,
                    letterSpacing: -.17,
                    height: 1.3,
                  ),
                ),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitle!,
                      style: Hip.sans(400, 13, color: Hip.muted, height: 1.4),
                    ),
                  ),
              ],
            ),
          ),
          if (chevron) ...[
            const SizedBox(width: 12),
            Icon(Icons.chevron_right, size: 17, color: Hip.muted2),
          ],
        ],
      ),
    );
    if (onTap == null) return row;
    return InkWell(
      onTap: onTap,
      borderRadius: HipRowSlot.cornersOf(context),
      child: row,
    );
  }
}

/// A small bordered action under a number.
class MiniAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const MiniAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 40),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Hip.line2,
            border: Border.all(color: Hip.line, width: 1.5),
            borderRadius: BorderRadius.circular(11),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: Hip.inkSoft),
              const SizedBox(width: 6),
              Flexible(
                child: Text(label, style: Hip.sans(650, 12.5, color: Hip.ink)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One line that scales down rather than breaking a number in two.
class OneLine extends StatelessWidget {
  const OneLine(this.child, {super.key});
  final Widget child;

  @override
  Widget build(BuildContext context) => FittedBox(
    fit: BoxFit.scaleDown,
    alignment: Alignment.centerLeft,
    child: child,
  );
}

/// The account number, masked unless shown, large, with Show and Copy.
/// Copy always copies the whole number, shown or not.
class AccountNumberBlock extends StatelessWidget {
  final String number;
  final bool revealed;
  final double size;
  final VoidCallback onToggle;
  final VoidCallback onCopy;
  const AccountNumberBlock({
    super.key,
    required this.number,
    required this.revealed,
    required this.onToggle,
    required this.onCopy,
    this.size = 20,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        OneLine(
          Text(
            revealed ? displayAccountNumber(number) : maskAccountNumber(number),
            style: Hip.mono(600, size, color: Hip.ink, letterSpacing: 1.2),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            MiniAction(
              icon: revealed
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              label: revealed ? S.accountHide : S.accountNumberShow,
              onTap: onToggle,
            ),
            MiniAction(
              icon: Icons.copy_outlined,
              label: S.accountCopy,
              onTap: onCopy,
            ),
          ],
        ),
      ],
    );
  }
}

/// A left-aligned muted sentence under a card (design `.subnote`).
class AccountNote extends StatelessWidget {
  final String text;
  const AccountNote(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
    child: Text(text, style: Hip.sans(400, 13, color: Hip.muted, height: 1.5)),
  );
}

/// The folded rare actions' header: "More options" with a chevron.
class MoreOptionsHeader extends StatelessWidget {
  final bool open;
  final VoidCallback onTap;
  const MoreOptionsHeader({super.key, required this.open, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      expanded: open,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 16, 6, 8),
          child: Row(
            children: [
              Icon(Icons.tune, size: 17, color: Hip.muted),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  S.accountMoreOptions,
                  style: Hip.sans(600, 14.5, color: Hip.muted),
                ),
              ),
              Icon(
                open ? Icons.expand_less : Icons.expand_more,
                size: 19,
                color: Hip.muted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A sheet's own content, scrolling inside the sheet when large text or a
/// small screen makes it taller than the screen.
class SheetScroll extends StatelessWidget {
  final Widget child;
  const SheetScroll({super.key, required this.child});

  @override
  Widget build(BuildContext context) =>
      Flexible(child: SingleChildScrollView(child: child));
}

/// What the Add a device sheet was closed with.
enum AddDeviceChoice { scan, code, legacyCode }

/// One place for every way onto another device: the new device's QR code
/// or short code read here, or the account number typed there.
///
/// With pairing v2 the two rows are Scan QR code and Enter code. Without it
/// (an older server, or a core with no v2 client yet) they are the 1.2.0
/// Scan and Show a code, which work against any server, so the sheet never
/// leads somewhere that cannot finish.
class AddDeviceSheet extends StatefulWidget {
  final bool v2;

  /// This device can approve: it holds the account's token.
  final bool canPair;
  final int? used;
  final int limit;

  /// The number to offer as the other way, or null when it is not kept
  /// here.
  final String? number;
  final Future<bool> Function() confirmReveal;
  final void Function(String number) onCopy;

  const AddDeviceSheet({
    super.key,
    required this.v2,
    required this.canPair,
    required this.used,
    required this.limit,
    required this.number,
    required this.confirmReveal,
    required this.onCopy,
  });

  @override
  State<AddDeviceSheet> createState() => _AddDeviceSheetState();
}

class _AddDeviceSheetState extends State<AddDeviceSheet> {
  bool _revealed = false;

  Future<void> _toggle() async {
    if (_revealed) {
      setState(() => _revealed = false);
      return;
    }
    final ok = await widget.confirmReveal();
    if (ok && mounted) setState(() => _revealed = true);
  }

  @override
  Widget build(BuildContext context) {
    final used = widget.used;
    final body = [
      S.accountAddShare(widget.limit),
      if (used != null) S.accountAddInUse(used, widget.limit),
      if (widget.canPair) widget.v2 ? S.accountAddHowV2 : S.accountAddHowLegacy,
    ].join(' ');
    final number = widget.number;
    return SheetScroll(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const HipSheetTitle(S.accountAddDevice),
          HipSheetBody(body),
          if (widget.canPair) ...[
            const SizedBox(height: 16),
            HipListGroup(
              children: [
                Builder(
                  builder: (c) => AccountRow(
                    leading: const AccountTile(
                      Icons.qr_code_scanner_outlined,
                      blue: true,
                    ),
                    title: S.accountScanQr,
                    titleColor: Hip.blue,
                    subtitle: widget.v2
                        ? S.accountScanQrSub
                        : S.setLinkedDevicesSub,
                    onTap: () => Navigator.of(c).pop(AddDeviceChoice.scan),
                  ),
                ),
                Builder(
                  builder: (c) => AccountRow(
                    leading: const AccountTile(Icons.pin_outlined),
                    title: widget.v2 ? S.accountEnterCode : S.accountLinkCode,
                    subtitle: widget.v2 ? S.accountEnterCodeSub : null,
                    onTap: () => Navigator.of(c).pop(
                      widget.v2
                          ? AddDeviceChoice.code
                          : AddDeviceChoice.legacyCode,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (number != null) ...[
            const CountedSectionLabel(S.accountOrSignIn),
            HipCard(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AccountNumberBlock(
                    number: number,
                    revealed: _revealed,
                    size: 21,
                    onToggle: _toggle,
                    onCopy: () => widget.onCopy(number),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    S.accountSignInNote,
                    style: Hip.sans(400, 12.5, color: Hip.muted, height: 1.4),
                  ),
                ],
              ),
            ),
          ],
          HipSheetActions(
            children: [
              Builder(
                builder: (c) => HipCta(
                  S.aCancel,
                  quiet: true,
                  onTap: () => Navigator.of(c).pop(),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
