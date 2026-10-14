/// Binary decoders for the full-text search types `tsvector` and `tsquery`.
///
/// Both render the binary structure exactly the way the server's text
/// output functions (`tsvectorout`, `tsqueryout`) do, so a column decodes
/// to the same `String` in text and in binary results.
///
/// Internal: not exported from the package barrel.
library;

import 'dart:convert' show utf8;
import 'dart:typed_data';

/// Binary `tsvector` (`tsvectorsend`) rendered the way `tsvectorout` does:
/// `'lexeme':1A,2 'other'`.
///
/// Wire layout: int32 lexeme count; per lexeme, the NUL-terminated text,
/// a uint16 position count and that many uint16 `WordEntryPos` (weight in
/// the 2 high bits, position in the 14 low bits).
String tsvectorFromBinary(Uint8List bytes) {
  final bd = ByteData.sublistView(bytes);
  final count = bd.getInt32(0, Endian.big);
  var o = 4;
  final out = <int>[];
  for (var i = 0; i < count; i++) {
    final end = bytes.indexOf(0, o);
    if (end < 0) {
      throw const FormatException('tsvector: lexeme not NUL-terminated');
    }
    if (i > 0) out.add(0x20);
    _quoted(out, bytes, o, end);
    o = end + 1;
    final npos = bd.getUint16(o, Endian.big);
    o += 2;
    for (var j = 0; j < npos; j++, o += 2) {
      final wep = bd.getUint16(o, Endian.big);
      out
        ..add(j == 0 ? 0x3A /* : */ : 0x2C /* , */)
        ..addAll('${wep & 0x3FFF}'.codeUnits);
      final w = wep >> 14; // 3=A 2=B 1=C; D (0) is not printed
      if (w != 0) out.add(0x44 - w); // 'A' = 0x41
    }
  }
  return utf8.decode(out);
}

/// `'` + lexeme with `'` and `\` doubled + `'`. Byte-level doubling is
/// safe in UTF-8: 0x27 and 0x5C never occur inside a multibyte sequence.
void _quoted(List<int> out, Uint8List bytes, int start, int end) {
  out.add(0x27);
  for (var k = start; k < end; k++) {
    final b = bytes[k];
    if (b == 0x27 || b == 0x5C) out.add(b);
    out.add(b);
  }
  out.add(0x27);
}

sealed class _TsNode {}

final class _TsVal extends _TsNode {
  _TsVal(this.start, this.end, this.weight, this.prefix);

  /// Lexeme bytes are `bytes[start..end)` of the payload.
  final int start;
  final int end;

  /// Weight mask: 8=A 4=B 2=C 1=D.
  final int weight;
  final bool prefix;
}

final class _TsNot extends _TsNode {
  _TsNot(this.child);
  final _TsNode child;
}

final class _TsBin extends _TsNode {
  _TsBin(this.op, this.distance, this.left, this.right);
  final int op;
  final int distance;
  final _TsNode left;
  final _TsNode right;
}

const _qiVal = 1, _qiOpr = 2;
const _opNot = 1, _opAnd = 2, _opOr = 3, _opPhrase = 4;

/// Operator priorities, as `tsearch_op_priority` in the server.
int _priority(int op) => switch (op) {
      _opNot => 4,
      _opAnd => 2,
      _opOr => 1,
      _opPhrase => 3,
      _ => throw FormatException('tsquery: unknown operator $op'),
    };

/// Binary `tsquery` (`tsquerysend`) rendered the way `tsqueryout` does.
///
/// Wire layout: int32 item count, then the items in prefix order. An
/// operand is uint8 type (1), uint8 weight mask, uint8 prefix flag and the
/// NUL-terminated lexeme; an operator is uint8 type (2), uint8 operator and,
/// for PHRASE only, an int16 distance. A binary operator is followed by its
/// **right** operand, then its left one.
String tsqueryFromBinary(Uint8List bytes) {
  final r = _TsReader(bytes);
  final size = r.int32();
  if (size == 0) return '';
  final root = r.node();
  if (r.items != size) {
    throw FormatException('tsquery: header says $size items, read ${r.items}');
  }
  final out = <int>[];
  _render(out, bytes, root, -1, false);
  return utf8.decode(out);
}

final class _TsReader {
  _TsReader(this.bytes) : bd = ByteData.sublistView(bytes);

  final Uint8List bytes;
  final ByteData bd;
  int o = 0;
  int items = 0;

  int int32() {
    final v = bd.getInt32(o, Endian.big);
    o += 4;
    return v;
  }

  int uint8() => bd.getUint8(o++);

  _TsNode node() {
    items++;
    final type = uint8();
    if (type == _qiVal) {
      final weight = uint8();
      final prefix = uint8() != 0;
      final end = bytes.indexOf(0, o);
      if (end < 0) {
        throw const FormatException('tsquery: operand not NUL-terminated');
      }
      final val = _TsVal(o, end, weight, prefix);
      o = end + 1;
      return val;
    }
    if (type != _qiOpr) {
      throw FormatException('tsquery: unknown item type $type');
    }
    final op = uint8();
    if (op == _opNot) return _TsNot(node());
    _priority(op); // rejects unknown operators
    var distance = 0;
    if (op == _opPhrase) {
      distance = bd.getInt16(o, Endian.big);
      o += 2;
    }
    final right = node();
    final left = node();
    return _TsBin(op, distance, left, right);
  }
}

void _ascii(List<int> out, String s) => out.addAll(s.codeUnits);

/// Mirror of the server's `infix`: a child gets parentheses when its
/// priority is lower than its parent's, or when it is a PHRASE on the
/// right of another PHRASE (phrase order matters).
void _render(
    List<int> out, Uint8List bytes, _TsNode n, int parent, bool rightOfPhrase) {
  switch (n) {
    case _TsVal(:final start, :final end, :final weight, :final prefix):
      _quoted(out, bytes, start, end);
      if (weight != 0 || prefix) {
        out.add(0x3A); // :
        if (prefix) out.add(0x2A); // *
        if (weight & 8 != 0) out.add(0x41); // A
        if (weight & 4 != 0) out.add(0x42); // B
        if (weight & 2 != 0) out.add(0x43); // C
        if (weight & 1 != 0) out.add(0x44); // D
      }
    case _TsNot(:final child):
      final p = _priority(_opNot);
      final paren = p < parent;
      if (paren) _ascii(out, '( ');
      out.add(0x21); // !
      _render(out, bytes, child, p, false);
      if (paren) _ascii(out, ' )');
    case _TsBin(:final op, :final distance, :final left, :final right):
      final p = _priority(op);
      final paren = p < parent || (op == _opPhrase && rightOfPhrase);
      if (paren) _ascii(out, '( ');
      _render(out, bytes, left, p, false);
      _ascii(
          out,
          switch (op) {
            _opAnd => ' & ',
            _opOr => ' | ',
            _ => distance == 1 ? ' <-> ' : ' <$distance> ',
          });
      _render(out, bytes, right, p, op == _opPhrase);
      if (paren) _ascii(out, ' )');
  }
}
