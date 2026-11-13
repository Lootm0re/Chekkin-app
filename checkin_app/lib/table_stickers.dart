import 'package:barcode_widget/barcode_widget.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart' hide Barcode;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'business_tools.dart';
import 'emulators.dart';
import 'theme.dart';

/// Table stickers: a QR code on each table that guests scan instead of
/// asking the staff for a code. The QR holds a token the server signed
/// (place, sticker, table label and version; see "Table stickers" in
/// functions/index.js); performCheckIn checks it and everything else.

/// What every sticker's QR text starts with. Other QR codes (a menu, Wi-Fi)
/// are ignored by the scanner instead of counting as wrong tries.
const String stickerTokenPrefix = 'CHK1.';

bool looksLikeStickerToken(String value) => value.startsWith(stickerTokenPrefix) && value.length < 500;

/// A table sticker as the owner's functions return it.
class TableSticker {
  final String id;
  final String label;
  final String token;

  const TableSticker({required this.id, required this.label, required this.token});

  factory TableSticker.fromMap(Map data) =>
      TableSticker(id: data['id'] as String, label: data['label'] as String, token: data['token'] as String);
}

// ---------------------------------------------------------------------------
// Scanning (guests)
// ---------------------------------------------------------------------------

/// The camera, looking for a Chekkin sticker. Pops with its token, or null
/// if the guest goes back or picks the code instead.
class ScanStickerScreen extends StatefulWidget {
  final String placeName;

  const ScanStickerScreen({super.key, required this.placeName});

  /// Tests put this in the camera's place; it calls back with what it "scanned".
  @visibleForTesting
  static Widget Function(BuildContext context, void Function(String value) onScanned)? debugCamera;

  @override
  State<ScanStickerScreen> createState() => _ScanStickerScreenState();
}

class _ScanStickerScreenState extends State<ScanStickerScreen> {
  MobileScannerController? controller;
  bool done = false;
  String? note;

  @override
  void initState() {
    super.initState();
    if (ScanStickerScreen.debugCamera == null) {
      controller = MobileScannerController(formats: const [BarcodeFormat.qrCode], detectionSpeed: DetectionSpeed.noDuplicates);
    }
  }

  @override
  void dispose() {
    controller?.dispose();
    super.dispose();
  }

  void _onScanned(String value) {
    if (done || !mounted) return;
    if (looksLikeStickerToken(value.trim())) {
      done = true;
      Navigator.of(context).pop(value.trim());
    } else {
      setState(() => note = 'That QR code isn\'t a Chekkin sticker. Look for the purple "Scan to check in" sticker on your table.');
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget camera = ScanStickerScreen.debugCamera?.call(context, _onScanned) ??
        MobileScanner(
          controller: controller,
          onDetect: (capture) {
            for (var barcode in capture.barcodes) {
              if (barcode.rawValue != null) _onScanned(barcode.rawValue!);
            }
          },
          errorBuilder: (context, error) => CameraProblem(error: error),
        );

    return Scaffold(
      backgroundColor: AppColors.ink,
      body: Stack(
        fit: StackFit.expand,
        children: [
          camera,
          // The frame to hold the sticker in.
          IgnorePointer(
            child: Center(
              child: Container(
                width: 250,
                height: 250,
                decoration: BoxDecoration(
                  border: Border.all(color: AppColors.yellow, width: 5),
                  borderRadius: BorderRadius.circular(AppShapes.cardRadius),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Material(
                        color: AppColors.card,
                        shape: const CircleBorder(),
                        child: IconButton(
                          tooltip: 'Back',
                          icon: const Icon(Icons.arrow_back_rounded, color: AppColors.ink),
                          onPressed: () => Navigator.of(context).maybePop(),
                        ),
                      ),
                      const SizedBox(width: 12),
                      // On a dark pill, readable over any camera picture.
                      Flexible(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          decoration: BoxDecoration(
                            color: AppColors.ink.withValues(alpha: 0.85),
                            borderRadius: BorderRadius.circular(AppShapes.fieldRadius),
                          ),
                          child: Text('Scan the table sticker', style: AppText.heading(size: 20, color: Colors.white)),
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: AppColors.card,
                      borderRadius: BorderRadius.circular(AppShapes.cardRadius),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('At ${widget.placeName}', style: AppText.heading(size: 18)),
                        const SizedBox(height: 4),
                        Text(
                          'Hold the "Scan to check in" sticker on your table inside the frame. You still need to be '
                          'at the place: your location is checked as usual.',
                          style: AppText.body(size: 15, color: AppColors.muted),
                        ),
                        if (note != null) ...[const SizedBox(height: 12), ErrorNote(message: note!)],
                        const SizedBox(height: 14),
                        OutlinedButton.icon(
                          icon: const Icon(Icons.dialpad_rounded),
                          label: const Text('Enter the code instead'),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Why the camera isn't showing: no permission, or it couldn't start.
class CameraProblem extends StatelessWidget {
  final MobileScannerException error;

  const CameraProblem({super.key, required this.error});

  static String get _settingsHint {
    if (kIsWeb) return 'Allow the camera for this site in your browser\'s settings, then try again.';
    return switch (defaultTargetPlatform) {
      TargetPlatform.iOS => 'Turn it on in Settings > Chekkin > Camera, then try again.',
      TargetPlatform.android => 'Turn it on in Settings > Apps > Chekkin > Permissions > Camera, then try again.',
      _ => 'Allow Chekkin to use the camera in your settings, then try again.',
    };
  }

  @override
  Widget build(BuildContext context) {
    bool denied = error.errorCode == MobileScannerErrorCode.permissionDenied;
    if (!denied) debugPrint('Camera failed: ${error.errorCode} ${error.errorDetails?.message}');
    return Container(
      color: AppColors.ink,
      padding: const EdgeInsets.fromLTRB(32, 120, 32, 260),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const IconSquare(color: AppColors.coral, icon: Icons.no_photography_rounded),
          const SizedBox(height: 16),
          Text(
            denied ? 'Camera access is off' : 'The camera didn\'t start',
            textAlign: TextAlign.center,
            style: AppText.heading(size: 22, color: Colors.white),
          ),
          const SizedBox(height: 8),
          Text(
            denied
                ? 'Chekkin only uses the camera to read the table sticker. $_settingsHint Or enter the code from the staff.'
                : 'You can enter the code from the staff instead.',
            textAlign: TextAlign.center,
            style: AppText.body(size: 16, color: Colors.white),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// The owner's stickers (My Business)
// ---------------------------------------------------------------------------

/// The place's table stickers: add one per table, print the sheet, and
/// "Reset all stickers" when printed ones must stop working.
class TableStickersCard extends StatefulWidget {
  final String placeId;
  final String placeName;

  const TableStickersCard({super.key, required this.placeId, required this.placeName});

  @override
  State<TableStickersCard> createState() => _TableStickersCardState();
}

class _TableStickersCardState extends State<TableStickersCard> {
  static const int collapsedCount = 6;

  final TextEditingController labelController = TextEditingController();
  List<TableSticker>? stickers;
  String? error;
  String? notice;
  bool busy = false;
  bool showAll = false;

  @override
  void initState() {
    super.initState();
    _run('getTableStickers', loading: true);
  }

  @override
  void dispose() {
    labelController.dispose();
    super.dispose();
  }

  /// Calls one of the sticker functions, which all answer with the list.
  Future<bool> _run(String name, {Map<String, Object?> extra = const {}, bool loading = false}) async {
    setState(() {
      busy = !loading;
      error = null;
      notice = null;
    });
    try {
      final response = await cloudFunctions.httpsCallable(name).call({'placeId': widget.placeId, ...extra});
      if (!mounted) return false;
      setState(() => stickers = [for (Map s in response.data['stickers']) TableSticker.fromMap(s)]);
      return true;
    } on FirebaseFunctionsException catch (e) {
      if (mounted) setState(() => error = e.message ?? 'Couldn\'t load your stickers.');
    } catch (e) {
      debugPrint('$name failed: $e');
      if (mounted) setState(() => error = 'Couldn\'t reach Chekkin. Please check your connection.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
    return false;
  }

  Future<void> _add() async {
    String label = labelController.text.trim();
    if (label.isEmpty || busy) return;
    if (await _run('createTableSticker', extra: {'label': label}) && mounted) {
      labelController.clear();
      setState(() => notice = 'Sticker for $label added. Print the sheet to put it on the table.');
    }
  }

  Future<void> _reset() async {
    bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset all stickers?'),
        content: Text(
          'Every printed sticker at ${widget.placeName} stops working straight away. Print the new sheet and '
          'replace the stickers on all tables. Use this if stickers were copied or photographed.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Keep stickers')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.coral, foregroundColor: AppColors.ink),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Reset all'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (await _run('resetTableStickers') && mounted) {
      setState(() => notice = 'All stickers reset. The old ones no longer work: print the new sheet.');
    }
  }

  void _print() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => StickerSheetScreen(placeName: widget.placeName, stickers: stickers!),
    ));
  }

  @override
  Widget build(BuildContext context) {
    var list = stickers ?? [];
    var shown = showAll ? list : list.take(collapsedCount).toList();
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const IconSquare(color: AppColors.coral, icon: Icons.qr_code_2_rounded, size: 52),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Table stickers', style: AppText.heading(size: 20)),
                      Text(
                        'Guests scan one to check in, without asking for a code.',
                        style: AppText.body(size: 14, color: AppColors.muted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: labelController,
                    enabled: !busy,
                    maxLength: 30,
                    textCapitalization: TextCapitalization.sentences,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _add(),
                    decoration: const InputDecoration(labelText: 'Table name', hintText: 'Like Table 4 or Terrace', counterText: ''),
                  ),
                ),
                const SizedBox(width: 10),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: labelController,
                  builder: (context, value, _) => ElevatedButton(
                    onPressed: busy || value.text.trim().isEmpty ? null : _add,
                    style: ElevatedButton.styleFrom(minimumSize: const Size(88, AppShapes.buttonHeight)),
                    child: const Text('Add'),
                  ),
                ),
              ],
            ),
            if (notice != null) ...[
              const SizedBox(height: 12),
              SuccessNote(text: notice!),
            ],
            if (error != null) ...[const SizedBox(height: 12), ErrorNote(message: error!)],
            const SizedBox(height: 16),
            if (stickers == null && error == null)
              const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()))
            else if (list.isEmpty && stickers != null)
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: AppColors.background, borderRadius: BorderRadius.circular(24)),
                child: Text(
                  'No stickers yet. Add your tables above, then print the sheet.',
                  style: AppText.body(size: 15, color: AppColors.muted),
                ),
              )
            else ...[
              for (var sticker in shown) _StickerRow(sticker: sticker),
              if (list.length > collapsedCount)
                TextButton(
                  onPressed: () => setState(() => showAll = !showAll),
                  child: Text(showAll ? 'Show fewer' : 'Show all ${formatNumber(list.length)} stickers'),
                ),
              const SizedBox(height: 8),
              ElevatedButton.icon(
                icon: const Icon(Icons.print_rounded),
                label: Text(list.length == 1 ? 'Print the sticker' : 'Print ${formatNumber(list.length)} stickers'),
                onPressed: busy ? null : _print,
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                icon: const Icon(Icons.restart_alt_rounded),
                label: const Text('Reset all stickers'),
                onPressed: busy ? null : _reset,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StickerRow extends StatelessWidget {
  final TableSticker sticker;

  const _StickerRow({required this.sticker});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: AppColors.background, borderRadius: BorderRadius.circular(20)),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(color: AppColors.card, borderRadius: BorderRadius.circular(10)),
            child: BarcodeWidget(
              barcode: Barcode.qrCode(),
              data: sticker.token,
              width: 48,
              height: 48,
              color: AppColors.ink,
              drawText: false,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(child: Text(sticker.label, style: AppText.heading(size: 18))),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// The printable sheet
// ---------------------------------------------------------------------------

/// The sticker sheet as a PDF, to print or share (PdfPreview's buttons).
class StickerSheetScreen extends StatelessWidget {
  final String placeName;
  final List<TableSticker> stickers;

  const StickerSheetScreen({super.key, required this.placeName, required this.stickers});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sticker sheet')),
      body: PdfPreview(
        build: (format) async => buildStickerSheet(format, placeName: placeName, stickers: stickers, fonts: await StickerFonts.load()),
        initialPageFormat: PdfPageFormat.a4,
        canChangePageFormat: false,
        canChangeOrientation: false,
        canDebug: false,
        pdfFileName: 'chekkin-stickers.pdf',
        actionBarTheme: const PdfActionBarTheme(backgroundColor: AppColors.lightPurple, iconColor: AppColors.ink),
        scrollViewDecoration: const BoxDecoration(color: AppColors.background),
      ),
    );
  }
}

/// Fredoka and Nunito for the PDF (PDFs embed their fonts).
class StickerFonts {
  final pw.Font heading;
  final pw.Font label;
  final pw.Font body;

  const StickerFonts({required this.heading, required this.label, required this.body});

  static Future<StickerFonts> load() async => StickerFonts(
        heading: await PdfGoogleFonts.fredokaBold(),
        label: await PdfGoogleFonts.fredokaSemiBold(),
        body: await PdfGoogleFonts.nunitoBold(),
      );
}

PdfColor _pdfColor(Color color) => PdfColor.fromInt(color.toARGB32());

/// Six stickers per page: "Scan to check in", the QR, the place name and the
/// table, in the app's colours.
Future<Uint8List> buildStickerSheet(
  PdfPageFormat format, {
  required String placeName,
  required List<TableSticker> stickers,
  required StickerFonts fonts,
}) async {
  const double gap = 16;
  const int columns = 2, rows = 3;
  var doc = pw.Document(title: 'Chekkin table stickers - $placeName', author: 'Chekkin');
  var ink = _pdfColor(AppColors.ink);

  pw.Widget sticker(TableSticker s, double width, double height) => pw.ClipRRect(
        horizontalRadius: 28,
        verticalRadius: 28,
        child: pw.Container(
          width: width,
          height: height,
          color: PdfColors.white,
          child: pw.Stack(
            children: [
              // Corner circles, clear of the text and the QR.
              pw.Positioned(right: -34, top: -34, child: _pdfCircle(78, AppColors.yellow)),
              pw.Positioned(left: -22, bottom: -22, child: _pdfCircle(54, AppColors.coral)),
              pw.Positioned.fill(
                child: pw.Padding(
                  padding: const pw.EdgeInsets.fromLTRB(18, 14, 18, 14),
                  child: pw.Column(
                    mainAxisAlignment: pw.MainAxisAlignment.center,
                    children: [
                      pw.Text('Scan to check in', style: pw.TextStyle(font: fonts.heading, fontSize: 20, color: ink)),
                      pw.SizedBox(height: 8),
                      pw.BarcodeWidget(
                        barcode: Barcode.qrCode(errorCorrectLevel: BarcodeQRCorrectionLevel.medium),
                        data: s.token,
                        width: 118,
                        height: 118,
                        color: ink,
                        drawText: false,
                      ),
                      pw.SizedBox(height: 8),
                      pw.Text(placeName,
                          maxLines: 1, style: pw.TextStyle(font: fonts.body, fontSize: 14, color: ink)),
                      pw.SizedBox(height: 6),
                      pw.Container(
                        padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 3),
                        decoration: pw.BoxDecoration(
                          color: _pdfColor(AppColors.yellow),
                          borderRadius: pw.BorderRadius.circular(10),
                        ),
                        child: pw.Text(s.label, style: pw.TextStyle(font: fonts.label, fontSize: 14, color: ink)),
                      ),
                    ],
                  ),
                ),
              ),
              // The border last, over the corner circles.
              pw.Positioned.fill(
                child: pw.Container(
                  decoration: pw.BoxDecoration(
                    border: pw.Border.all(color: _pdfColor(AppColors.purple), width: 4),
                    borderRadius: pw.BorderRadius.circular(28),
                  ),
                ),
              ),
            ],
          ),
        ),
      );

  var margin = const pw.EdgeInsets.all(28);
  double cellWidth = (format.width - margin.horizontal - gap * (columns - 1)) / columns;
  double cellHeight = (format.height - margin.vertical - gap * (rows - 1)) / rows;
  for (int start = 0; start < stickers.length; start += columns * rows) {
    var page = stickers.skip(start).take(columns * rows).toList();
    doc.addPage(pw.Page(
      pageFormat: format,
      margin: margin,
      build: (_) => pw.Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [for (var s in page) sticker(s, cellWidth, cellHeight)],
      ),
    ));
  }
  return doc.save();
}

pw.Widget _pdfCircle(double size, Color color) => pw.Container(
      width: size,
      height: size,
      decoration: pw.BoxDecoration(color: _pdfColor(color), shape: pw.BoxShape.circle),
    );
