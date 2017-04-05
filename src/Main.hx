
class Main {
  
  static public function main() {
    var dmp = new DiffMatchPatch();
    
    assertEquals(0, dmp.diff_commonPrefix('abc', 'xyz'));

    // Non-null case.
    assertEquals(4, dmp.diff_commonPrefix('1234abcdef', '1234xyz'));

    // Whole case.
    assertEquals(4, dmp.diff_commonPrefix('1234', '1234xyz'));
  }
  
  static function assertEquals(expected, actual):Void {
    if (expected != actual) {
      throw 'expected ' + Std.string(expected) + ' but was ' + Std.string(actual);
    }
  }
}