/**
 * Test Harness for Diff Match and Patch
 *
 * Copyright 2006 Google Inc.
 * http://code.google.com/p/google-diff-match-patch/
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import DiffMatchPatch;

import utest.Assert.*;


class Helpers {

  public function new() {
    
  }

  // If expected and actual are the equivalent, pass the test.
  //NOTE(hx): msg has been repositioned as last arg! And we're using Dynamic,
  //          and Assert.same() instead of porting _equivalent()!!
  static public function assertEquivalent(expected:Dynamic, actual:Dynamic, ?msg) {
    if (msg == null) msg = 'Expected: \'' + expected + '\' Actual: \'' + actual + '\'';
    same(expected, actual, true, msg);
    
    /*if (_equivalent(expected, actual)) {
      equals(msg, String.toString(expected), String.toString(actual));
    } else {
      equals(msg, expected, actual);
    }*/
  }


  // Are a and b the equivalent? -- Recursive.
  /*static function _equivalent(a, b) {
    if (a == b) {
      return true;
    }
    if (typeof a == 'object' && typeof b == 'object' && a !== null && b !== null) {
      if (a.toString() != b.toString()) {
        return false;
      }
      for (var p in a) {
        if (!_equivalent(a[p], b[p])) {
          return false;
        }
      }
      for (var p in b) {
        if (!_equivalent(a[p], b[p])) {
          return false;
        }
      }
      return true;
    }
    return false;
  }*/


  static public function diff_rebuildtexts(diffs:Diff) {
    // Construct the two texts which made up the diff originally.
    var text1 = '';
    var text2 = '';
    for (x in 0...diffs.length) {
      if (diffs[x][0] != DIFF_INSERT) {
        text1 += diffs[x][1];
      }
      if (diffs[x][0] != DIFF_DELETE) {
        text2 += diffs[x][1];
      }
    }
    return [text1, text2];
  }
  
  // calling this function will set a breakpoint at caller site
  inline static public function jsDebugger(?label:String) {
  #if (nodejs || js)
    if (label != null) untyped __js__('debugger; {0}', label);
    else untyped __js__('debugger');
  #end
  }
}