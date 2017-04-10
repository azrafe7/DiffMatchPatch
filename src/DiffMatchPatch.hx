/**
 * Diff Match and Patch
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

/**
 * @fileoverview Computes the difference between two texts to create a patch.
 * Applies the patch onto another text, allowing for errors.
 * @author fraser@google.com (Neil Fraser)
 * 
 * @author azrafe7 (port to haxe from https://github.com/GerHobbelt/google-diff-match-patch - mirror of the original at https://code.google.com/p/google-diff-match-patch/)
 */

/* 
 * hx notes (search for 'NOTE(hx)' throughout code):
 *  - diff ops (del,insert,eq) extracted in DiffOp
 *  - wrap String in SString (so I can swap test with unifill vs plain haxe strings in the future)
 *  - Diff represent a single diff
 * 
 *  - check falsey values (null/empty/etc.)
 *  - in js ("" == false) is true
 *  - check differences from js (splice/concat accept multiple values there) - splice -> spliceInsert
 *  - in haxe [].push() returns an index
 * 
 *  - watch for regexes (search for 'match')
 *  - check Date
 *  - encode/decodeURI -> urlEncode/Decode (does haxe urlDecode throw on failing?)
 *  - watch for fallthroughs in switch cases
 * 
 */

import unifill.CodePoint;

using unifill.Unifill;
using DiffMatchPatch.Internal; 


class DiffMatchPatch {

  // Defaults.
  // Redefine these in your program to override the defaults.

  // Number of seconds to map a diff before giving up (0 for infinity).
  public var Diff_Timeout:Float = 1.0;
  // Cost of an empty edit operation in terms of edit characters.
  public var Diff_EditCost:Int = 4;
  // At what point is no match declared (0.0 = perfection, 1.0 = very loose).
  public var Match_Threshold:Float = 0.5;
  // How far to search for a match (0 = exact location, 1000+ = broad match).
  // A match this many characters away from the expected location will add
  // 1.0 to the score (0.0 is a perfect match).
  public var Match_Distance:Int = 1000;
  // When deleting a large block of text (over ~64 characters), how close do
  // the contents have to be to match the expected contents. (0.0 = perfection,
  // 1.0 = very loose).  Note that Match_Threshold controls how closely the
  // end points of a delete need to match.
  public var Patch_DeleteThreshold:Float = 0.5;
  // Chunk size for context length.
  public var Patch_Margin:Int = 4;

  // The number of bits in an int.
  public var Match_MaxBits:Int = 32;
  
  
  /**
   * Class containing the diff, match and patch methods.
   * @constructor
   */
  public function new() {

  }

  /**
   * Find the differences between two texts.  Simplifies the problem by stripping
   * any common prefix or suffix off the texts before diffing.
   * @param {string} text1 Old string to be diffed.
   * @param {string} text2 New string to be diffed.
   * @param {boolean=} opt_checklines Optional speedup flag. If present and false,
   *     then don't run a line-level diff first to identify the changed areas.
   *     Defaults to true, which does a faster, slightly less optimal diff.
   * @param {number} opt_deadline Optional time when the diff should be complete
   *     by.  Used internally for recursive calls.  Users should set DiffTimeout
   *     instead.
   * @return {!Array.<!diff_match_patch.Diff>} Array of diff tuples.
   */
  public function diff_main(text1:SString, text2:SString, ?opt_checklines:Bool, ?opt_deadline:Float):Diff {
    // Set a deadline by which time the diff must be complete.
    if (opt_deadline == null) {
      if (this.Diff_Timeout <= 0) {
        opt_deadline = Internal.NUMBER_MAX;
      } else {
        //NOTE(hx): check getTime()
        opt_deadline = (Date.now().getTime()) + this.Diff_Timeout * 1000;
      }
    }
    var deadline = opt_deadline;

    // Check for null inputs.
    if (text1 == null || text2 == null) {
      throw new Error('Null input. (diff_main)');
    }

    // Check for equality (speedup).
    //NOTE(hx): why equality and then check for falsey? (ooohh... now I get it - ref commit 'fix trivial diff null case' from 04/10/2017)
    if (text1 == text2) {
      if (!text1.isNullOrEmpty()) {
        return [new SingleDiff(DIFF_EQUAL, text1)];
      }
      return [];
    }

    if (opt_checklines == null) {
      opt_checklines = true;
    }
    var checklines = opt_checklines;

    // Trim off common prefix (speedup).
    var commonlength = this.diff_commonPrefix(text1, text2);
    var commonprefix = text1.substring(0, commonlength);
    text1 = text1.substring(commonlength);
    text2 = text2.substring(commonlength);

    // Trim off common suffix (speedup).
    commonlength = this.diff_commonSuffix(text1, text2);
    var commonsuffix = text1.substring(text1.length - commonlength);
    text1 = text1.substring(0, text1.length - commonlength);
    text2 = text2.substring(0, text2.length - commonlength);

    // Compute the diff on the middle block.
    var diffs = this.diff_compute_(text1, text2, checklines, deadline);

    // Restore the prefix and suffix.
    if (!commonprefix.isNullOrEmpty()) {
      diffs.unshift(new SingleDiff(DIFF_EQUAL, commonprefix));
    }
    if (!commonsuffix.isNullOrEmpty()) {
      diffs.push(new SingleDiff(DIFF_EQUAL, commonsuffix));
    }
    this.diff_cleanupMerge(diffs);
    return diffs;
  };


  /**
   * Find the differences between two texts.  Assumes that the texts do not
   * have any common prefix or suffix.
   * @param {string} text1 Old string to be diffed.
   * @param {string} text2 New string to be diffed.
   * @param {boolean} checklines Speedup flag.  If false, then don't run a
   *     line-level diff first to identify the changed areas.
   *     If true, then run a faster, slightly less optimal diff.
   * @param {number} deadline Time when the diff should be complete by.
   * @return {!Array.<!diff_match_patch.Diff>} Array of diff tuples.
   * @private
   */
  function diff_compute_(text1:SString, text2:SString, checklines:Bool, deadline:Float):Diff {
    var diffs:Diff;

    //NOTE(hx): more falsey values
    if (text1.isNullOrEmpty()) {
      // Just add some text (speedup).
      return ([new SingleDiff(DIFF_INSERT, text2)] : Diff);
    }

    if (text2.isNullOrEmpty()) {
      // Just delete some text (speedup).
      return ([new SingleDiff(DIFF_DELETE, text1)] : Diff);
    }

    var longtext = text1.length > text2.length ? text1 : text2;
    var shorttext = text1.length > text2.length ? text2 : text1;
    var i = longtext.indexOf(shorttext);
    if (i != -1) {
      // Shorter text is inside the longer text (speedup).
      diffs = [new SingleDiff(DIFF_INSERT, longtext.substring(0, i)),
               new SingleDiff(DIFF_EQUAL, shorttext),
               new SingleDiff(DIFF_INSERT, longtext.substring(i + shorttext.length))];
      // Swap insertions for deletions if diff is reversed.
      if (text1.length > text2.length) {
        diffs[0][0] = diffs[2][0] = DIFF_DELETE;
      }
      return diffs;
    }

    if (shorttext.length == 1) {
      // Single character string.
      // After the previous speedup, the character can't be an equality.
      return [new SingleDiff(DIFF_DELETE, text1), new SingleDiff(DIFF_INSERT, text2)];
    }

    // Check to see if the problem can be split in two.
    var hm = this.diff_halfMatch_(text1, text2);
    if (hm != null) {
      // A half-match was found, sort out the return data.
      var text1_a = hm[0];
      var text1_b = hm[1];
      var text2_a = hm[2];
      var text2_b = hm[3];
      var mid_common = hm[4];
      // Send both pairs off for separate processing.
      var diffs_a = this.diff_main(text1_a, text2_a, checklines, deadline);
      var diffs_b = this.diff_main(text1_b, text2_b, checklines, deadline);
      // Merge the results.
      //NOTE(hx): concat with multiple args
      return diffs_a.concat([new SingleDiff(DIFF_EQUAL, mid_common)]).concat(diffs_b);
    }

    if (checklines && text1.length > 100 && text2.length > 100) {
      return this.diff_lineMode_(text1, text2, deadline);
    }

    return this.diff_bisect_(text1, text2, deadline);
  };


  /**
   * Do a quick line-level diff on both strings, then rediff the parts for
   * greater accuracy.
   * This speedup can produce non-minimal diffs.
   * @param {string} text1 Old string to be diffed.
   * @param {string} text2 New string to be diffed.
   * @param {number} deadline Time when the diff should be complete by.
   * @return {!Array.<!diff_match_patch.Diff>} Array of diff tuples.
   * @private
   */
  function diff_lineMode_(text1:SString, text2:SString, deadline) {
    // Scan the text on a line-by-line basis first.
    var a = this.diff_linesToChars_(text1, text2);
    text1 = a.chars1;
    text2 = a.chars2;
    var linearray = a.lineArray;

    var diffs = this.diff_main(text1, text2, false, deadline);

    // Convert the diff back to original text.
    this.diff_charsToLines_(diffs, linearray);
    // Eliminate freak matches (e.g. blank lines)
    this.diff_cleanupSemantic(diffs);

    // Rediff any replacement blocks, this time character-by-character.
    // Add a dummy entry at the end.
    diffs.push(new SingleDiff(DIFF_EQUAL, ''));
    var pointer = 0;
    var count_delete = 0;
    var count_insert = 0;
    var text_delete = '';
    var text_insert = '';
    while (pointer < diffs.length) {
      switch (diffs[pointer][0]) {
        case DIFF_INSERT:
          count_insert++;
          text_insert += diffs[pointer][1];
          //break;
        case DIFF_DELETE:
          count_delete++;
          text_delete += diffs[pointer][1];
          //break;
        case DIFF_EQUAL:
          // Upon reaching an equality, check for prior redundancies.
          if (count_delete >= 1 && count_insert >= 1) {
            // Delete the offending records and add the merged ones.
            diffs.splice(pointer - count_delete - count_insert,
                         count_delete + count_insert);
            pointer = pointer - count_delete - count_insert;
            var a = this.diff_main(text_delete, text_insert, false, deadline);
            //NOTE(hx): check loop
            var j = a.length - 1;
            while (j >= 0) {
              diffs.spliceInsert(pointer, 0, [a[j]]);
              j--;
            }
            pointer = pointer + a.length;
          }
          count_insert = 0;
          count_delete = 0;
          text_delete = '';
          text_insert = '';
          //break;
      }
      pointer++;
    }
    diffs.pop();  // Remove the dummy entry at the end.

    return diffs;
  };


  /**
   * Find the 'middle snake' of a diff, split the problem in two
   * and return the recursively constructed diff.
   * See Myers 1986 paper: An O(ND) Difference Algorithm and Its Variations.
   * @param {string} text1 Old string to be diffed.
   * @param {string} text2 New string to be diffed.
   * @param {number} deadline Time at which to bail if not yet complete.
   * @return {!Array.<!diff_match_patch.Diff>} Array of diff tuples.
   * @private
   */
  public function diff_bisect_(text1:SString, text2:SString, deadline:Float):Diff {
    // Cache the text lengths to prevent multiple calls.
    var text1_length = text1.length;
    var text2_length = text2.length;
    var max_d = Math.ceil((text1_length + text2_length) / 2);
    var v_offset = max_d;
    var v_length = 2 * max_d;
    //NOTE(hx): new fixed array (with nullable values)
    var v1:NullIntArray = [for (i in 0...v_length) null];
    var v2:NullIntArray = [for (i in 0...v_length) null];
    // Setting all elements to -1 is faster in Chrome & Firefox than mixing
    // integers and undefined.
    var x = 0;
    while (x < v_length) {
      v1[x] = -1;
      v2[x] = -1;
      x++;
    }
    v1[v_offset + 1] = 0;
    v2[v_offset + 1] = 0;
    var delta = text1_length - text2_length;
    // If the total number of characters is odd, then the front path will collide
    // with the reverse path.
    var front = (delta % 2 != 0);
    // Offsets for start and end of k loop.
    // Prevents mapping of space beyond the grid.
    var k1start = 0;
    var k1end = 0;
    var k2start = 0;
    var k2end = 0;
    //NOTE(hx): check nested loops/break
    var d = 0;
    //for (var d = 0; d < max_d; d++) {
    while (d < max_d) {
      // Bail out if deadline is reached.
      if (Date.now().getTime() > deadline) {
        break;
      }

      // Walk the front path one step.
      var k1 = -d + k1start;
      //for (var k1 = -d + k1start; k1 <= d - k1end; k1 += 2) {
      while (k1 <= d - k1end) {
        var k1_offset = v_offset + k1;
        var x1;
        if (k1 == -d || (k1 != d && v1[k1_offset - 1] < v1[k1_offset + 1])) {
          x1 = v1[k1_offset + 1];
        } else {
          x1 = v1[k1_offset - 1] + 1;
        }
        var y1 = x1 - k1;
        while (x1 < text1_length && y1 < text2_length &&
               text1.charAt(x1) == text2.charAt(y1)) {
          x1++;
          y1++;
        }
        v1[k1_offset] = x1;
        if (x1 > text1_length) {
          // Ran off the right of the graph.
          k1end += 2;
        } else if (y1 > text2_length) {
          // Ran off the bottom of the graph.
          k1start += 2;
        } else if (front) {
          var k2_offset = v_offset + delta - k1;
          if (k2_offset >= 0 && k2_offset < v_length && v2[k2_offset] != -1) {
            // Mirror x2 onto top-left coordinate system.
            var x2 = text1_length - v2[k2_offset];
            if (x1 >= x2) {
              // Overlap detected.
              return this.diff_bisectSplit_(text1, text2, x1, y1, deadline);
            }
          }
        }
        
        k1 += 2;
      }

      // Walk the reverse path one step.
      var k2 = -d + k2start;
      //for (var k2 = -d + k2start; k2 <= d - k2end; k2 += 2) {
      while (k2 <= d - k2end) {
        var k2_offset = v_offset + k2;
        var x2;
        if (k2 == -d || (k2 != d && v2[k2_offset - 1] < v2[k2_offset + 1])) {
          x2 = v2[k2_offset + 1];
        } else {
          x2 = v2[k2_offset - 1] + 1;
        }
        var y2 = x2 - k2;
        while (x2 < text1_length && y2 < text2_length &&
               text1.charAt(text1_length - x2 - 1) ==
               text2.charAt(text2_length - y2 - 1)) {
          x2++;
          y2++;
        }
        v2[k2_offset] = x2;
        if (x2 > text1_length) {
          // Ran off the left of the graph.
          k2end += 2;
        } else if (y2 > text2_length) {
          // Ran off the top of the graph.
          k2start += 2;
        } else if (!front) {
          var k1_offset = v_offset + delta - k2;
          if (k1_offset >= 0 && k1_offset < v_length && v1[k1_offset] != -1) {
            var x1 = v1[k1_offset];
            var y1 = v_offset + x1 - k1_offset;
            // Mirror x2 onto top-left coordinate system.
            x2 = text1_length - x2;
            if (x1 >= x2) {
              // Overlap detected.
              return this.diff_bisectSplit_(text1, text2, x1, y1, deadline);
            }
          }
        }
        
        k2 += 2;
      }
      
      d++;
    }
    // Diff took too long and hit the deadline or
    // number of diffs equals number of characters, no commonality at all.
    return [new SingleDiff(DIFF_DELETE, text1), new SingleDiff(DIFF_INSERT, text2)];
  };


  /**
   * Given the location of the 'middle snake', split the diff in two parts
   * and recurse.
   * @param {string} text1 Old string to be diffed.
   * @param {string} text2 New string to be diffed.
   * @param {number} x Index of split point in text1.
   * @param {number} y Index of split point in text2.
   * @param {number} deadline Time at which to bail if not yet complete.
   * @return {!Array.<!diff_match_patch.Diff>} Array of diff tuples.
   * @private
   */
  function diff_bisectSplit_(text1:SString, text2:SString, x:Int, y:Int, deadline) {
    var text1a = text1.substring(0, x);
    var text2a = text2.substring(0, y);
    var text1b = text1.substring(x);
    var text2b = text2.substring(y);

    // Compute both diffs serially.
    var diffs = this.diff_main(text1a, text2a, false, deadline);
    var diffsb = this.diff_main(text1b, text2b, false, deadline);

    return diffs.concat(diffsb);
  };


  /**
   * Split two texts into an array of strings.  Reduce the texts to a string of
   * hashes where each Unicode character represents one line.
   * @param {string} text1 First string.
   * @param {string} text2 Second string.
   * @return {{chars1: string, chars2: string, lineArray: !Array.<string>}}
   *     An object containing the encoded text1, the encoded text2 and
   *     the array of unique strings.
   *     The zeroth element of the array of unique strings is intentionally blank.
   * @private
   */
  public function diff_linesToChars_(text1:SString, text2:SString):LinesToCharsObj {
    var lineArray:Array<SString> = [];  // e.g. lineArray[4] == 'Hello\n'
    //NOTE(hx): line hash - from obj to something haxe specific (Map or Dynamic)
    var lineHash = new Map<SString, Int>();   // e.g. lineHash['Hello\n'] == 4

    // '\x00' is a valid character, but various debuggers don't like it.
    // So we'll insert a junk entry to avoid generating a null character.
    lineArray[0] = '';

    /**
     * Split a text into an array of strings.  Reduce the texts to a string of
     * hashes where each Unicode character represents one line.
     * Modifies linearray and linehash through being a closure.
     * @param {string} text String to encode.
     * @return {string} Encoded string.
     * @private
     */
    function diff_linesToCharsMunge_(text:SString) {
      var chars:SString = '';
      // Walk the text, pulling out a substring for each line.
      // text.split('\n') would would temporarily double our memory footprint.
      // Modifying text would create many large strings to garbage collect.
      var lineStart = 0;
      var lineEnd = -1;
      // Keeping our own length variable is faster than looking it up.
      var lineArrayLength = lineArray.length;
      while (lineEnd < text.length - 1) {
        lineEnd = text.indexOf('\n', lineStart);
        if (lineEnd == -1) {
          lineEnd = text.length - 1;
        }
        var line = text.substring(lineStart, lineEnd + 1);
        lineStart = lineEnd + 1;

        //NOTE(hx): hasOwnProperty (I predict this will break things somewhere)
        if (lineHash[line] != null) { //NOTE(hx): undefined
          chars += SString.fromCharCode(lineHash[line]);
        } else {
          chars += SString.fromCharCode(lineArrayLength);
          lineHash[line] = lineArrayLength;
          lineArray[lineArrayLength++] = line;
        }
      }
      return chars;
    }

    var chars1:SString = diff_linesToCharsMunge_(text1);
    var chars2:SString = diff_linesToCharsMunge_(text2);
    return {chars1: chars1, chars2: chars2, lineArray: lineArray};
  };


  /**
   * Rehydrate the text in a diff from a string of line hashes to real lines of
   * text.
   * @param {!Array.<!diff_match_patch.Diff>} diffs Array of diff tuples.
   * @param {!Array.<string>} lineArray Array of unique strings.
   * @private
   */
  public function diff_charsToLines_(diffs:Diff, lineArray:Array<SString>) {
    //NOTE(hx): loops
    for (x in 0...diffs.length) {
      var chars:SString = diffs[x][1];
      var text = [];
      for (y in 0...chars.length) {
        text[y] = lineArray[chars.charCodeAt(y)];
      }
      diffs[x][1] = text.join('');
    }
  };


  /**
   * Determine the common prefix of two strings.
   * @param {string} text1 First string.
   * @param {string} text2 Second string.
   * @return {number} The number of characters common to the start of each
   *     string.
   */
  public function diff_commonPrefix(text1:SString, text2:SString):Int {
    // Quick check for common null cases.
    if (text1 == null || text2 == null || text1.charAt(0) != text2.charAt(0)) {
      return 0;
    }
    // Binary search.
    // Performance analysis: http://neil.fraser.name/news/2007/10/09/
    var pointermin:Int = 0;
    var pointermax:Int = Std.int(Math.min(text1.length, text2.length));
    var pointermid = pointermax;
    var pointerstart = 0;
    while (pointermin < pointermid) {
      if (text1.substring(pointerstart, pointermid) ==
          text2.substring(pointerstart, pointermid)) {
        pointermin = pointermid;
        pointerstart = pointermin;
      } else {
        pointermax = pointermid;
      }
      pointermid = Math.floor((pointermax - pointermin) / 2 + pointermin);
    }
    return pointermid;
  };


  /**
   * Determine the common suffix of two strings.
   * @param {string} text1 First string.
   * @param {string} text2 Second string.
   * @return {number} The number of characters common to the end of each string.
   */
  public function diff_commonSuffix(text1:SString, text2:SString):Int {
    // Quick check for common null cases.
    //NOTE(hx): check falsey
    if (text1 == null || text2 == null ||
        text1.charAt(text1.length - 1) != text2.charAt(text2.length - 1)) {
      return 0;
    }
    // Binary search.
    // Performance analysis: http://neil.fraser.name/news/2007/10/09/
    var pointermin:Int = 0;
    var pointermax = Std.int(Math.min(text1.length, text2.length));
    var pointermid = pointermax;
    var pointerend = 0;
    while (pointermin < pointermid) {
      if (text1.substring(text1.length - pointermid, text1.length - pointerend) ==
          text2.substring(text2.length - pointermid, text2.length - pointerend)) {
        pointermin = pointermid;
        pointerend = pointermin;
      } else {
        pointermax = pointermid;
      }
      pointermid = Math.floor((pointermax - pointermin) / 2 + pointermin);
    }
    return pointermid;
  };


  /**
   * Determine if the suffix of one string is the prefix of another.
   * @param {string} text1 First string.
   * @param {string} text2 Second string.
   * @return {number} The number of characters common to the end of the first
   *     string and the start of the second string.
   * @private
   */
  public function diff_commonOverlap_(text1:SString, text2:SString) {
    // Cache the text lengths to prevent multiple calls.
    var text1_length = text1.length;
    var text2_length = text2.length;
    // Eliminate the null case.
    if (text1_length == 0 || text2_length == 0) {
      return 0;
    }
    // Truncate the longer string.
    if (text1_length > text2_length) {
      text1 = text1.substring(text1_length - text2_length);
    } else if (text1_length < text2_length) {
      text2 = text2.substring(0, text1_length);
    }
    var text_length = Std.int(Math.min(text1_length, text2_length));
    // Quick check for the worst case.
    if (text1 == text2) {
      return text_length;
    }

    // Start by looking for a single character match
    // and increase length until no match is found.
    // Performance analysis: http://neil.fraser.name/news/2010/11/04/
    var best = 0;
    var length = 1;
    while (true) {
      var pattern = text1.substring(text_length - length);
      var found = text2.indexOf(pattern);
      if (found == -1) {
        return best;
      }
      length += found;
      if (found == 0 || text1.substring(text_length - length) ==
          text2.substring(0, length)) {
        best = length;
        length++;
      }
    }
  };


  /**
   * Do the two texts share a substring which is at least half the length of the
   * longer text?
   * This speedup can produce non-minimal diffs.
   * @param {string} text1 First string.
   * @param {string} text2 Second string.
   * @return {Array.<string>} Five element Array, containing the prefix of
   *     text1, the suffix of text1, the prefix of text2, the suffix of
   *     text2 and the common middle.  Or null if there was no match.
   * @private
   */
  public function diff_halfMatch_(text1:SString, text2:SString):Array<SString> {
    if (this.Diff_Timeout <= 0) {
      // Don't risk returning a non-optimal diff if we have unlimited time.
      return null;
    }
    var longtext = text1.length > text2.length ? text1 : text2;
    var shorttext = text1.length > text2.length ? text2 : text1;
    if (longtext.length < 4 || shorttext.length * 2 < longtext.length) {
      return null;  // Pointless.
    }
    var dmp = this;  // 'this' becomes 'window' in a closure.

    /**
     * Does a substring of shorttext exist within longtext such that the substring
     * is at least half the length of longtext?
     * Closure, but does not reference any external variables.
     * @param {string} longtext Longer string.
     * @param {string} shorttext Shorter string.
     * @param {number} i Start index of quarter length substring within longtext.
     * @return {Array.<string>} Five element Array, containing the prefix of
     *     longtext, the suffix of longtext, the prefix of shorttext, the suffix
     *     of shorttext and the common middle.  Or null if there was no match.
     * @private
     */
    function diff_halfMatchI_(longtext:SString, shorttext:SString, i) {
      // Start with a 1/4 length substring at position i as a seed.
      var seed = longtext.substring(i, i + Math.floor(longtext.length / 4));
      var j = -1;
      var best_common = '';
      //NOTE(hx): Local variables best_* used without being initialized
      var best_longtext_a = '', best_longtext_b = '', best_shorttext_a = '', best_shorttext_b = '';
      while ((j = shorttext.indexOf(seed, j + 1)) != -1) {
        var prefixLength = dmp.diff_commonPrefix(longtext.substring(i),
                                                 shorttext.substring(j));
        var suffixLength = dmp.diff_commonSuffix(longtext.substring(0, i),
                                                 shorttext.substring(0, j));
        if (best_common.length < suffixLength + prefixLength) {
          best_common = shorttext.substring(j - suffixLength, j) +
              shorttext.substring(j, j + prefixLength);
          best_longtext_a = longtext.substring(0, i - suffixLength);
          best_longtext_b = longtext.substring(i + prefixLength);
          best_shorttext_a = shorttext.substring(0, j - suffixLength);
          best_shorttext_b = shorttext.substring(j + prefixLength);
        }
      }
      if (best_common.length * 2 >= longtext.length) {
        return [best_longtext_a, best_longtext_b,
                best_shorttext_a, best_shorttext_b, best_common];
      } else {
        return null;
      }
    }

    // First check if the second quarter is the seed for a half-match.
    var hm1 = diff_halfMatchI_(longtext, shorttext,
                               Math.ceil(longtext.length / 4));
    // Check again based on the third quarter.
    var hm2 = diff_halfMatchI_(longtext, shorttext,
                               Math.ceil(longtext.length / 2));
    var hm;
    if (hm1 == null && hm2 == null) {
      return null;
    } else if (hm2 == null) {
      hm = hm1;
    } else if (hm1 == null) {
      hm = hm2;
    } else {
      // Both matched.  Select the longest.
      hm = hm1[4].length > hm2[4].length ? hm1 : hm2;
    }

    // A half-match was found, sort out the return data.
    var text1_a, text1_b, text2_a, text2_b;
    if (text1.length > text2.length) {
      text1_a = hm[0];
      text1_b = hm[1];
      text2_a = hm[2];
      text2_b = hm[3];
    } else {
      text2_a = hm[0];
      text2_b = hm[1];
      text1_a = hm[2];
      text1_b = hm[3];
    }
    var mid_common = hm[4];
    return [text1_a, text1_b, text2_a, text2_b, mid_common];
  };


  /**
   * Reduce the number of edits by eliminating semantically trivial equalities.
   * @param {!Array.<!diff_match_patch.Diff>} diffs Array of diff tuples.
   */
  public function diff_cleanupSemantic(diffs:Diff) {
    var changes = false;
    //NOTE(hx): using a map here, as it can have negative indices
    var equalities = new Map<Int, Int>();  // Stack of indices where equalities are found.
    var equalitiesLength = 0;  // Keeping our own length var is faster in JS.
    /** @type {?string} */
    var lastequality:SString = null;
    // Always equal to diffs[equalities[equalitiesLength - 1]][1]
    var pointer = 0;  // Index of current position.
    // Number of characters that changed prior to the equality.
    var length_insertions1 = 0;
    var length_deletions1 = 0;
    // Number of characters that changed after the equality.
    var length_insertions2 = 0;
    var length_deletions2 = 0;
    while (pointer < diffs.length) {
      if (diffs[pointer][0] == DIFF_EQUAL) {  // Equality found.
        equalities[equalitiesLength++] = pointer;
        length_insertions1 = length_insertions2;
        length_deletions1 = length_deletions2;
        length_insertions2 = 0;
        length_deletions2 = 0;
        lastequality = diffs[pointer][1];
      } else {  // An insertion or deletion.
        if (diffs[pointer][0] == DIFF_INSERT) {
          length_insertions2 += diffs[pointer][1].length;
        } else {
          length_deletions2 += diffs[pointer][1].length;
        }
        // Eliminate an equality that is smaller or equal to the edits on both
        // sides of it.
        if (lastequality != null && (lastequality.length <=
            Math.max(length_insertions1, length_deletions1)) &&
            (lastequality.length <= Math.max(length_insertions2,
                                             length_deletions2))) {
          // Duplicate record.
          diffs.spliceInsert(equalities[equalitiesLength - 1], 0, [new SingleDiff(DIFF_DELETE, lastequality)]);
          // Change second copy to insert.
          diffs[equalities[equalitiesLength - 1] + 1][0] = DIFF_INSERT;
          // Throw away the equality we just deleted.
          equalitiesLength--;
          // Throw away the previous equality (it needs to be reevaluated).
          equalitiesLength--;
          pointer = equalitiesLength > 0 ? equalities[equalitiesLength - 1] : -1;
          length_insertions1 = 0;  // Reset the counters.
          length_deletions1 = 0;
          length_insertions2 = 0;
          length_deletions2 = 0;
          lastequality = null;
          changes = true;
        }
      }
      pointer++;
    }

    // Normalize the diff.
    if (changes) {
      this.diff_cleanupMerge(diffs);
    }
    this.diff_cleanupSemanticLossless(diffs);

    // Find any overlaps between deletions and insertions.
    // e.g: <del>abcxxx</del><ins>xxxdef</ins>
    //   -> <del>abc</del>xxx<ins>def</ins>
    // e.g: <del>xxxabc</del><ins>defxxx</ins>
    //   -> <ins>def</ins>xxx<del>abc</del>
    // Only extract an overlap if it is as big as the edit ahead or behind it.
    pointer = 1;
    while (pointer < diffs.length) {
      if (diffs[pointer - 1][0] == DIFF_DELETE &&
          diffs[pointer][0] == DIFF_INSERT) {
        var deletion = diffs[pointer - 1][1];
        var insertion = diffs[pointer][1];
        var overlap_length1 = this.diff_commonOverlap_(deletion, insertion);
        var overlap_length2 = this.diff_commonOverlap_(insertion, deletion);
        if (overlap_length1 >= overlap_length2) {
          if (overlap_length1 >= deletion.length / 2 ||
              overlap_length1 >= insertion.length / 2) {
            // Overlap found.  Insert an equality and trim the surrounding edits.
            diffs.spliceInsert(pointer, 0, [new SingleDiff(DIFF_EQUAL, insertion.substring(0, overlap_length1))]);
            diffs[pointer - 1][1] =
                deletion.substring(0, deletion.length - overlap_length1);
            diffs[pointer + 1][1] = insertion.substring(overlap_length1);
            pointer++;
          }
        } else {
          if (overlap_length2 >= deletion.length / 2 ||
              overlap_length2 >= insertion.length / 2) {
            // Reverse overlap found.
            // Insert an equality and swap and trim the surrounding edits.
            diffs.spliceInsert(pointer, 0, [new SingleDiff(DIFF_EQUAL, deletion.substring(0, overlap_length2))]);
            diffs[pointer - 1][0] = DIFF_INSERT;
            diffs[pointer - 1][1] =
                insertion.substring(0, insertion.length - overlap_length2);
            diffs[pointer + 1][0] = DIFF_DELETE;
            diffs[pointer + 1][1] =
                deletion.substring(overlap_length2);
            pointer++;
          }
        }
        pointer++;
      }
      pointer++;
    }
  };


  /**
   * Look for single edits surrounded on both sides by equalities
   * which can be shifted sideways to align the edit to a word boundary.
   * e.g: The c<ins>at c</ins>ame. -> The <ins>cat </ins>came.
   * @param {!Array.<!diff_match_patch.Diff>} diffs Array of diff tuples.
   */
  public function diff_cleanupSemanticLossless(diffs:Diff) {
    /**
     * Given two strings, compute a score representing whether the internal
     * boundary falls on logical boundaries.
     * Scores range from 6 (best) to 0 (worst).
     * Closure, but does not reference any external variables.
     * @param {string} one First string.
     * @param {string} two Second string.
     * @return {number} The score.
     * @private
     */
    //NOTE(hx): regexes ahead!!
    function diff_cleanupSemanticScore_(one:SString, two:SString) {
      if (one.isNullOrEmpty() || two.isNullOrEmpty()) {
        // Edges are the best.
        return 6;
      }

      // Each port of this function behaves slightly differently due to
      // subtle differences in each language's definition of things like
      // 'whitespace'.  Since this function's purpose is largely cosmetic,
      // the choice has been made to use each language's native features
      // rather than force total conformity.
      var char1 = one.charAt(one.length - 1);
      var char2 = two.charAt(0);
      var nonAlphaNumeric1 = nonAlphaNumericRegex_.match(char1);
      var nonAlphaNumeric2 = nonAlphaNumericRegex_.match(char2);
      var whitespace1 = nonAlphaNumeric1 &&
          whitespaceRegex_.match(char1);
      var whitespace2 = nonAlphaNumeric2 &&
          whitespaceRegex_.match(char2);
      var lineBreak1 = whitespace1 &&
          linebreakRegex_.match(char1);
      var lineBreak2 = whitespace2 &&
          linebreakRegex_.match(char2);
      var blankLine1 = lineBreak1 &&
          blanklineEndRegex_.match(one);
      var blankLine2 = lineBreak2 &&
          blanklineStartRegex_.match(two);

      if (blankLine1 || blankLine2) {
        // Five points for blank lines.
        return 5;
      } else if (lineBreak1 || lineBreak2) {
        // Four points for line breaks.
        return 4;
      } else if (nonAlphaNumeric1 && !whitespace1 && whitespace2) {
        // Three points for end of sentences.
        return 3;
      } else if (whitespace1 || whitespace2) {
        // Two points for whitespace.
        return 2;
      } else if (nonAlphaNumeric1 || nonAlphaNumeric2) {
        // One point for non-alphanumeric.
        return 1;
      }
      return 0;
    }

    var pointer = 1;
    // Intentionally ignore the first and last element (don't need checking).
    while (pointer < diffs.length - 1) {
      if (diffs[pointer - 1][0] == DIFF_EQUAL &&
          diffs[pointer + 1][0] == DIFF_EQUAL) {
        // This is a single edit surrounded by equalities.
        var equality1:SString = diffs[pointer - 1][1];
        var edit:SString = diffs[pointer][1];
        var equality2:SString = diffs[pointer + 1][1];

        // First, shift the edit as far left as possible.
        var commonOffset:Int = this.diff_commonSuffix(equality1, edit);
        //NOTE(hx): != 0
        if (commonOffset != 0) {
          var commonString = edit.substring(edit.length - commonOffset);
          equality1 = equality1.substring(0, equality1.length - commonOffset);
          edit = commonString + edit.substring(0, edit.length - commonOffset);
          equality2 = commonString + equality2;
        }

        // Second, step character by character right, looking for the best fit.
        var bestEquality1 = equality1;
        var bestEdit = edit;
        var bestEquality2 = equality2;
        var bestScore = diff_cleanupSemanticScore_(equality1, edit) +
            diff_cleanupSemanticScore_(edit, equality2);
        while (edit.charAt(0) == equality2.charAt(0)) {
          equality1 += edit.charAt(0);
          edit = edit.substring(1) + equality2.charAt(0);
          equality2 = equality2.substring(1);
          var score = diff_cleanupSemanticScore_(equality1, edit) +
              diff_cleanupSemanticScore_(edit, equality2);
          // The >= encourages trailing rather than leading whitespace on edits.
          if (score >= bestScore) {
            bestScore = score;
            bestEquality1 = equality1;
            bestEdit = edit;
            bestEquality2 = equality2;
          }
        }

        if (diffs[pointer - 1][1] != bestEquality1) {
          // We have an improvement, save it back to the diff.
          if (!bestEquality1.isNullOrEmpty()) {
            diffs[pointer - 1][1] = bestEquality1;
          } else {
            diffs.splice(pointer - 1, 1);
            pointer--;
          }
          diffs[pointer][1] = bestEdit;
          if (!bestEquality2.isNullOrEmpty()) {
            diffs[pointer + 1][1] = bestEquality2;
          } else {
            diffs.splice(pointer + 1, 1);
            pointer--;
          }
        }
      }
      pointer++;
    }
  };

  // Define some regex patterns for matching boundaries.
  static var nonAlphaNumericRegex_ = ~/[^a-zA-Z0-9]/;
  static var whitespaceRegex_ = ~/\s/;
  static var linebreakRegex_ = ~/[\r\n]/;
  static var blanklineEndRegex_ = ~/\n\r?\n$/;
  static var blanklineStartRegex_ = ~/^\r?\n\r?\n/;

  /**
   * Reduce the number of edits by eliminating operationally trivial equalities.
   * @param {!Array.<!diff_match_patch.Diff>} diffs Array of diff tuples.
   */
  public function diff_cleanupEfficiency(diffs:Diff) {
    var changes = false;
    var equalities = [];  // Stack of indices where equalities are found.
    var equalitiesLength = 0;  // Keeping our own length var is faster in JS.
    /** @type {?string} */
    var lastequality:SString = null;
    // Always equal to diffs[equalities[equalitiesLength - 1]][1]
    var pointer = 0;  // Index of current position.
    // Is there an insertion operation before the last equality.
    var pre_ins = false;
    // Is there a deletion operation before the last equality.
    var pre_del = false;
    // Is there an insertion operation after the last equality.
    var post_ins = false;
    // Is there a deletion operation after the last equality.
    var post_del = false;
    while (pointer < diffs.length) {
      if (diffs[pointer][0] == DIFF_EQUAL) {  // Equality found.
        if (diffs[pointer][1].length < this.Diff_EditCost &&
            (post_ins || post_del)) {
          // Candidate found.
          equalities[equalitiesLength++] = pointer;
          pre_ins = post_ins;
          pre_del = post_del;
          lastequality = diffs[pointer][1];
        } else {
          // Not a candidate, and can never become one.
          equalitiesLength = 0;
          lastequality = null;
        }
        post_ins = post_del = false;
      } else {  // An insertion or deletion.
        if (diffs[pointer][0] == DIFF_DELETE) {
          post_del = true;
        } else {
          post_ins = true;
        }
        /*
         * Five types to be split:
         * <ins>A</ins><del>B</del>XY<ins>C</ins><del>D</del>
         * <ins>A</ins>X<ins>C</ins><del>D</del>
         * <ins>A</ins><del>B</del>X<ins>C</ins>
         * <ins>A</del>X<ins>C</ins><del>D</del>
         * <ins>A</ins><del>B</del>X<del>C</del>
         */
        if (lastequality != null && ((pre_ins && pre_del && post_ins && post_del) ||
                             ((lastequality.length < this.Diff_EditCost / 2) &&
                              (pre_ins.boolAsInt() + pre_del.boolAsInt() + post_ins.boolAsInt() + post_del.boolAsInt()) == 3))) {
          // Duplicate record.
          diffs.spliceInsert(equalities[equalitiesLength - 1], 0, [new SingleDiff(DIFF_DELETE, lastequality)]);
          // Change second copy to insert.
          diffs[equalities[equalitiesLength - 1] + 1][0] = DIFF_INSERT;
          equalitiesLength--;  // Throw away the equality we just deleted;
          lastequality = null;
          if (pre_ins && pre_del) {
            // No changes made which could affect previous entry, keep going.
            post_ins = post_del = true;
            equalitiesLength = 0;
          } else {
            equalitiesLength--;  // Throw away the previous equality.
            pointer = equalitiesLength > 0 ?
                equalities[equalitiesLength - 1] : -1;
            post_ins = post_del = false;
          }
          changes = true;
        }
      }
      pointer++;
    }

    if (changes) {
      this.diff_cleanupMerge(diffs);
    }
  };


  /**
   * Reorder and merge like edit sections.  Merge equalities.
   * Any edit section can move as long as it doesn't cross an equality.
   * @param {!Array.<!diff_match_patch.Diff>} diffs Array of diff tuples.
   */
  public function diff_cleanupMerge(diffs:Diff) {
    diffs.push(new SingleDiff(DIFF_EQUAL, ''));  // Add a dummy entry at the end.
    var pointer = 0;
    var count_delete = 0;
    var count_insert = 0;
    var text_delete:SString = '';
    var text_insert:SString = '';
    var commonlength;
    while (pointer < diffs.length) {
      switch (diffs[pointer][0]) {
        case DIFF_INSERT:
          count_insert++;
          text_insert += diffs[pointer][1];
          pointer++;
          //break;
        case DIFF_DELETE:
          count_delete++;
          text_delete += diffs[pointer][1];
          pointer++;
          //break;
        case DIFF_EQUAL:
          // Upon reaching an equality, check for prior redundancies.
          if (count_delete + count_insert > 1) {
            if (count_delete != 0 && count_insert != 0) {
              // Factor out any common prefixies.
              commonlength = this.diff_commonPrefix(text_insert, text_delete);
              if (commonlength != 0) {
                if ((pointer - count_delete - count_insert) > 0 &&
                    diffs[pointer - count_delete - count_insert - 1][0] ==
                    DIFF_EQUAL) {
                  diffs[pointer - count_delete - count_insert - 1][1] +=
                      text_insert.substring(0, commonlength);
                } else {
                  diffs.spliceInsert(0, 0, [new SingleDiff(DIFF_EQUAL, text_insert.substring(0, commonlength))]);
                  pointer++;
                }
                text_insert = text_insert.substring(commonlength);
                text_delete = text_delete.substring(commonlength);
              }
              // Factor out any common suffixies.
              commonlength = this.diff_commonSuffix(text_insert, text_delete);
              if (commonlength != 0) {
                diffs[pointer][1] = text_insert.substring(text_insert.length -
                    commonlength) + diffs[pointer][1];
                text_insert = text_insert.substring(0, text_insert.length -
                    commonlength);
                text_delete = text_delete.substring(0, text_delete.length -
                    commonlength);
              }
            }
            // Delete the offending records and add the merged ones.
            if (count_delete == 0) {
              diffs.spliceInsert(pointer - count_insert,
                  count_delete + count_insert, 
                  [new SingleDiff(DIFF_INSERT, text_insert)]);
            } else if (count_insert == 0) {
              diffs.spliceInsert(pointer - count_delete,
                  count_delete + count_insert,
                  [new SingleDiff(DIFF_DELETE, text_delete)]);
            } else {
              diffs.spliceInsert(pointer - count_delete - count_insert,
                  count_delete + count_insert,
                  [new SingleDiff(DIFF_DELETE, text_delete),
                   new SingleDiff(DIFF_INSERT, text_insert)]);
            }
            //NOTE(hx): count falsey values
            pointer = pointer - count_delete - count_insert +
                      (count_delete != 0 ? 1 : 0) + (count_insert != 0 ? 1 : 0) + 1;
          } else if (pointer != 0 && diffs[pointer - 1][0] == DIFF_EQUAL) {
            // Merge this equality with the previous one.
            diffs[pointer - 1][1] += diffs[pointer][1];
            diffs.splice(pointer, 1);
          } else {
            pointer++;
          }
          count_insert = 0;
          count_delete = 0;
          text_delete = '';
          text_insert = '';
          //break;
      }
    }
    if (diffs[diffs.length - 1][1] == '') {
      diffs.pop();  // Remove the dummy entry at the end.
    }

    // Second pass: look for single edits surrounded on both sides by equalities
    // which can be shifted sideways to eliminate an equality.
    // e.g: A<ins>BA</ins>C -> <ins>AB</ins>AC
    var changes = false;
    pointer = 1;
    // Intentionally ignore the first and last element (don't need checking).
    //NOTE(hx): recheck forced typing
    while (pointer < diffs.length - 1) {
      if (diffs[pointer - 1][0] == DIFF_EQUAL &&
          diffs[pointer + 1][0] == DIFF_EQUAL) {
        // This is a single edit surrounded by equalities.
        if ((diffs[pointer][1] : SString).substring((diffs[pointer][1] : SString).length -
            (diffs[pointer - 1][1] : SString).length) == diffs[pointer - 1][1]) {
          // Shift the edit over the previous equality.
          diffs[pointer][1] = diffs[pointer - 1][1] +
              (diffs[pointer][1] : SString).substring(0, (diffs[pointer][1] : SString).length -
                                          (diffs[pointer - 1][1] : SString).length);
          diffs[pointer + 1][1] = diffs[pointer - 1][1] + diffs[pointer + 1][1];
          diffs.splice(pointer - 1, 1);
          changes = true;
        } else if ((diffs[pointer][1] : SString).substring(0, diffs[pointer + 1][1].length) ==
            diffs[pointer + 1][1]) {
          // Shift the edit over the next equality.
          diffs[pointer - 1][1] += diffs[pointer + 1][1];
          diffs[pointer][1] =
              (diffs[pointer][1] : SString).substring(diffs[pointer + 1][1].length) +
              diffs[pointer + 1][1];
          diffs.splice(pointer + 1, 1);
          changes = true;
        }
      }
      pointer++;
    }
    // If shifts were made, the diff needs reordering and another shift sweep.
    if (changes) {
      this.diff_cleanupMerge(diffs);
    }
  };


  /**
   * loc is a location in text1, compute and return the equivalent location in
   * text2.
   * e.g. 'The cat' vs 'The big cat', 1->1, 5->8
   * @param {!Array.<!diff_match_patch.Diff>} diffs Array of diff tuples.
   * @param {number} loc Location within text1.
   * @return {number} Location within text2.
   */
  public function diff_xIndex(diffs:Diff, loc) {
    var chars1 = 0;
    var chars2 = 0;
    var last_chars1 = 0;
    var last_chars2 = 0;
    var x = 0;
    //for (x = 0; x < diffs.length; x++) {
    while (x < diffs.length) {
      if (diffs[x][0] != DIFF_INSERT) {  // Equality or deletion.
        chars1 += diffs[x][1].length;
      }
      if (diffs[x][0] != DIFF_DELETE) {  // Equality or insertion.
        chars2 += diffs[x][1].length;
      }
      if (chars1 > loc) {  // Overshot the location.
        break;
      }
      last_chars1 = chars1;
      last_chars2 = chars2;
      
      x++;
    }
    // Was the location was deleted?
    if (diffs.length != x && diffs[x][0] == DIFF_DELETE) {
      return last_chars2;
    }
    // Add the remaining character length.
    return last_chars2 + (loc - last_chars1);
  };


  /**
   * Convert a diff array into a pretty HTML report.
   * @param {!Array.<!diff_match_patch.Diff>} diffs Array of diff tuples.
   * @return {string} HTML representation.
   */
  public function diff_prettyHtml(diffs:Diff) {
    var html = [];
    var pattern_amp = ~/&/g;
    var pattern_lt = ~/</g;
    var pattern_gt = ~/>/g;
    var pattern_para = ~/\n/g;
    var x = 0;
    //for (var x = 0; x < diffs.length; x++) {
    while (x < diffs.length) {
      var op = diffs[x][0];    // Operation (insert, delete, equal)
      var data:SString = diffs[x][1];  // Text of change.
      //NOTE(hx): rearrange replace
      var text:SString = pattern_amp.replace(data, '&amp;');
      text = pattern_lt.replace(text, '&lt;');
      text = pattern_gt.replace(text, '&gt;');
      text = pattern_para.replace(text, '&para;<br>');
      switch (op) {
        case DIFF_INSERT:
          html[x] = '<ins style="background:#e6ffe6;">' + text + '</ins>';
          //break;
        case DIFF_DELETE:
          html[x] = '<del style="background:#ffe6e6;">' + text + '</del>';
          //break;
        case DIFF_EQUAL:
          html[x] = '<span>' + text + '</span>';
          //break;
      }
      
      x++;
    }
    return html.join('');
  };


  /**
   * Compute and return the source text (all equalities and deletions).
   * @param {!Array.<!diff_match_patch.Diff>} diffs Array of diff tuples.
   * @return {string} Source text.
   */
  public function diff_text1(diffs:Diff):SString {
    var text = [];
    for (x in 0...diffs.length) {
      if (diffs[x][0] != DIFF_INSERT) {
        text[x] = diffs[x][1];
      } else { //NOTE(hx): set to empty string, as in js ['a', null, 'b'].join('') is ok (null will be skipped), not so elsewhere
        text[x] = "";
      }
    }
    return text.join('');
  };


  /**
   * Compute and return the destination text (all equalities and insertions).
   * @param {!Array.<!diff_match_patch.Diff>} diffs Array of diff tuples.
   * @return {string} Destination text.
   */
  public function diff_text2(diffs:Diff):SString {
    var text = [];
    for (x in 0...diffs.length) {
      if (diffs[x][0] != DIFF_DELETE) {
        text[x] = diffs[x][1];
      } else { //NOTE(hx): set to empty string, as in js ['a', null, 'b'].join('') is ok (null will be skipped), not so elsewhere
        text[x] = "";
      }
    }
    return text.join('');
  };


  /**
   * Compute the Levenshtein distance; the number of inserted, deleted or
   * substituted characters.
   * @param {!Array.<!diff_match_patch.Diff>} diffs Array of diff tuples.
   * @return {number} Number of changes.
   */
  public function diff_levenshtein(diffs:Diff) {
    var levenshtein:Int = 0;
    var insertions = 0;
    var deletions = 0;
    for (x in 0...diffs.length) {
      var op = diffs[x][0];
      var data = diffs[x][1];
      switch (op) {
        case DIFF_INSERT:
          insertions += data.length;
          //break;
        case DIFF_DELETE:
          deletions += data.length;
          //break;
        case DIFF_EQUAL:
          // A deletion and an insertion is one substitution.
          levenshtein += Std.int(Math.max(insertions, deletions));
          insertions = 0;
          deletions = 0;
          //break;
      }
    }
    levenshtein += Std.int(Math.max(insertions, deletions));
    return levenshtein;
  };


  /**
   * Crush the diff into an encoded string which describes the operations
   * required to transform text1 into text2.
   * E.g. =3\t-2\t+ing  -> Keep 3 chars, delete 2 chars, insert 'ing'.
   * Operations are tab-separated.  Inserted text is escaped using %xx notation.
   * @param {!Array.<!diff_match_patch.Diff>} diffs Array of diff tuples.
   * @return {string} Delta text.
   */
  public function diff_toDelta(diffs:Diff) {
    var text = [];
    for (x in 0...diffs.length) {
      switch (diffs[x][0]) {
        case DIFF_INSERT:
          text[x] = '+' + StringTools.urlEncode(diffs[x][1]); //NOTE(hx): encodeURI -> urlEncode
          //break;
        case DIFF_DELETE:
          text[x] = '-' + diffs[x][1].length;
          //break;
        case DIFF_EQUAL:
          text[x] = '=' + diffs[x][1].length;
          //break;
      }
    }
    return ~/%20/g.replace(text.join('\t'), ' ');
  };


  /**
   * Given the original text1, and an encoded string which describes the
   * operations required to transform text1 into text2, compute the full diff.
   * @param {string} text1 Source string for the diff.
   * @param {string} delta Delta text.
   * @return {!Array.<!diff_match_patch.Diff>} Array of diff tuples.
   * @throws {!Error} If invalid input.
   */
  public function diff_fromDelta(text1, delta):Diff {
    var diffs:Diff = [];
    var diffsLength = 0;  // Keeping our own length var is faster in JS.
    var pointer = 0;  // Cursor in text1
    var tokens = ~/\t/g.split(delta);
    for (x in 0...tokens.length) {
      // Each token begins with a one character parameter which specifies the
      // operation of this token (delete, insert, equality).
      var param = tokens[x].substring(1);
      switch (tokens[x].charAt(0)) {
        case '+':
          try {
            diffs[diffsLength++] = new SingleDiff(DIFF_INSERT, StringTools.urlDecode(param)); //NOTE(hx): decodeURI -> urlDecode
          } catch (ex:Dynamic) {
            // Malformed URI sequence.
            throw new Error('Illegal escape in diff_fromDelta: ' + param);
          }
          //break;
        case '-',
          // Fall through.
        /*case*/ '=':
          var n = Std.parseInt(param); //NOTE(hx): was parseInt(param, 10)
          if (Math.isNaN(n) || n < 0) {
            throw new Error('Invalid number in diff_fromDelta: ' + param);
          }
          var text = text1.substring(pointer, pointer += n);
          if (tokens[x].charAt(0) == '=') {
            diffs[diffsLength++] = new SingleDiff(DIFF_EQUAL, text);
          } else {
            diffs[diffsLength++] = new SingleDiff(DIFF_DELETE, text);
          }
          //break;
        default:
          // Blank tokens are ok (from a trailing \t).
          // Anything else is an error.
          if (tokens[x].isNullOrEmpty()) { //NOTE(hx): not sure this is what the original meant (we'll see)
            throw new Error('Invalid diff operation in diff_fromDelta: ' +
                            tokens[x]);
          }
      }
    }
    if (pointer != text1.length) {
      throw new Error('Delta length (' + pointer +
          ') does not equal source text length (' + text1.length + ').');
    }
    return diffs;
  };


  //  MATCH FUNCTIONS


  /**
   * Locate the best instance of 'pattern' in 'text' near 'loc'.
   * @param {string} text The text to search.
   * @param {string} pattern The pattern to search for.
   * @param {number} loc The location to search around.
   * @return {number} Best match index or -1.
   */
  public function match_main(text:SString, pattern:SString, ?loc:Int) {
    // Check for null inputs.
    if (text == null || pattern == null || loc == null) {
      throw new Error('Null input. (match_main)');
    }

    loc = Std.int(Math.max(0, Math.min(loc, text.length)));
    if (text == pattern) {
      // Shortcut (potentially not guaranteed by the algorithm)
      return 0;
    } else if (text.length == 0) {
      // Nothing to match.
      return -1;
    } else if (text.substring(loc, loc + pattern.length) == pattern) {
      // Perfect match at the perfect spot!  (Includes case of null pattern)
      return loc;
    } else {
      // Do a fuzzy compare.
      return this.match_bitap_(text, pattern, loc);
    }
  };


  /**
   * Locate the best instance of 'pattern' in 'text' near 'loc' using the
   * Bitap algorithm.
   * @param {string} text The text to search.
   * @param {string} pattern The pattern to search for.
   * @param {number} loc The location to search around.
   * @return {number} Best match index or -1.
   * @private
   */
  public function match_bitap_(text:SString, pattern:SString, loc:Int):Int {
    if (pattern.length > this.Match_MaxBits) {
      throw new Error('Pattern too long for this browser.');
    }

    // Initialise the alphabet.
    var s = this.match_alphabet_(pattern);

    var dmp = this;  // 'this' becomes 'window' in a closure.

    /**
     * Compute and return the score for a match with e errors and x location.
     * Accesses loc and pattern through being a closure.
     * @param {number} e Number of errors in match.
     * @param {number} x Location of match.
     * @return {number} Overall score for match (0.0 = good, 1.0 = bad).
     * @private
     */
    function match_bitapScore_(e:Int, x:Int):Float {
      var accuracy = e / pattern.length;
      var proximity = Std.int(Math.abs(loc - x));
      if (dmp.Match_Distance == 0) {
        // Dodge divide by zero error.
        return proximity != 0 ? 1.0 : accuracy;
      }
      return accuracy + (proximity / dmp.Match_Distance);
    }

    //NOTE(hx): save text.length, so we don't need to look it up later (this is to fix cases like "abc".charAt(5) below, which yelds "" in js)
    var textLength = text.length;
    // Highest score beyond which we give up.
    var score_threshold = this.Match_Threshold;
    // Is there a nearby exact match? (speedup)
    var best_loc = text.indexOf(pattern, loc);
    if (best_loc != -1) {
      score_threshold = Math.min(match_bitapScore_(0, best_loc), score_threshold);
      // What about in the other direction? (speedup)
      best_loc = text.lastIndexOf(pattern, loc + pattern.length);
      if (best_loc != -1) {
        score_threshold =
            Math.min(match_bitapScore_(0, best_loc), score_threshold);
      }
    }

    // Initialise the bit arrays.
    var matchmask = 1 << (pattern.length - 1);
    best_loc = -1;

    var bin_min, bin_mid;
    var bin_max = pattern.length + textLength;
    var last_rd:NullIntArray = null; //NOTE(hx): init first
    //NOTE(hx): nested loops
    for (d in 0...pattern.length) {
      // Scan for the best match; each iteration allows for one more error.
      // Run a binary search to determine how far from 'loc' we can stray at this
      // error level.
      bin_min = 0;
      bin_mid = bin_max;
      while (bin_min < bin_mid) {
        if (match_bitapScore_(d, loc + bin_mid) <= score_threshold) {
          bin_min = bin_mid;
        } else {
          bin_max = bin_mid;
        }
        bin_mid = Math.floor((bin_max - bin_min) / 2 + bin_min);
      }
      // Use the result from this iteration as the maximum for the next.
      bin_max = bin_mid;
      var start = Std.int(Math.max(1, loc - bin_mid + 1));
      var finish = Std.int(Math.min(loc + bin_mid, textLength)) + pattern.length;

      var rd:NullIntArray = [for (i in 0...finish + 2) null]; //NOTE(hx): init array by length
      rd[finish + 1] = (1 << d) - 1;
      var j = finish;
      //for (var j = finish; j >= start; j--) {
      while (j >= start) {
        // The alphabet (s) is a sparse hash, so the following line generates
        // warnings.
        //NOTE(hx): set it to 0 when null, or indexed out of bounds
        var charMatch = (j - 1 < textLength) ? s[text.charAt(j - 1)] : 0;
        if (charMatch == null) charMatch = 0;
        if (d == 0) {  // First pass: exact match.
          rd[j] = ((rd[j + 1] << 1) | 1) & charMatch;
        } else {  // Subsequent passes: fuzzy match.
          rd[j] = (((rd[j + 1] << 1) | 1) & charMatch) |
                  (((last_rd[j + 1] | last_rd[j]) << 1) | 1) |
                  last_rd[j + 1];
        }
        //NOTE(hx): check conditional
        var rdj = rd[j];
        if (rdj == null) rdj = 0;
        if ((rdj & matchmask) != 0) { 
          var score = match_bitapScore_(d, j - 1);
          // This match will almost certainly be better than any existing match.
          // But check anyway.
          if (score <= score_threshold) {
            // Told you so.
            score_threshold = score;
            best_loc = j - 1;
            if (best_loc > loc) {
              // When passing loc, don't exceed our current distance from loc.
              start = Std.int(Math.max(1, 2 * loc - best_loc));
            } else {
              // Already passed loc, downhill from here on in.
              break;
            }
          }
        }
        
        j--;
      }
      // No hope for a (better) match at greater error levels.
      if (match_bitapScore_(d + 1, loc) > score_threshold) {
        break;
      }
      last_rd = rd;
    }
    return best_loc;
  };


  /**
   * Initialise the alphabet for the Bitap algorithm.
   * @param {string} pattern The text to encode.
   * @return {!Object} Hash of character locations.
   * @private
   */
  public function match_alphabet_(pattern:SString) {
    var s = new Map<SString, Int>(); //NOTE(hx): mmmhh... 
    for (i in 0...pattern.length) {
      s[pattern.charAt(i)] = 0;
    }
    for (i in 0...pattern.length) {
      s[pattern.charAt(i)] |= 1 << (pattern.length - i - 1);
    }
    return s;
  };


  //  PATCH FUNCTIONS


  /**
   * Increase the context until it is unique,
   * but don't let the pattern expand beyond Match_MaxBits.
   * @param {!diff_match_patch.patch_obj} patch The patch to grow.
   * @param {string} text Source text.
   * @private
   */
  function patch_addContext_(patch, text:SString) {
    if (text.length == 0) {
      return;
    }
    var pattern = text.substring(patch.start2, patch.start2 + patch.length1);
    var padding = 0;

    // Look for the first and last matches of pattern in text.  If two different
    // matches are found, increase the pattern length.
    while (text.indexOf(pattern) != text.lastIndexOf(pattern) &&
           pattern.length < this.Match_MaxBits - this.Patch_Margin -
           this.Patch_Margin) {
      padding += this.Patch_Margin;
      pattern = text.substring(patch.start2 - padding,
                               patch.start2 + patch.length1 + padding);
    }
    // Add one chunk for good luck.
    padding += this.Patch_Margin;

    //NOTE(hx): double check 2 casts below
    // Add the prefix.
    var prefix:SString = cast text.substring(patch.start2 - padding, patch.start2);
    if (!Internal.isNullOrEmpty(prefix)) {
      patch.diffs.unshift(new SingleDiff(DIFF_EQUAL, prefix));
    }
    // Add the suffix.
    var suffix:SString = cast text.substring(patch.start2 + patch.length1,
                                patch.start2 + patch.length1 + padding);
    if (!Internal.isNullOrEmpty(suffix)) {
      patch.diffs.push(new SingleDiff(DIFF_EQUAL, suffix));
    }

    // Roll back the start points.
    patch.start1 -= prefix.length;
    patch.start2 -= prefix.length;
    // Extend the lengths.
    patch.length1 += prefix.length + suffix.length;
    patch.length2 += prefix.length + suffix.length;
  };


  /**
   * Compute a list of patches to turn text1 into text2.
   * Use diffs if provided, otherwise compute it ourselves.
   * There are four ways to call this function, depending on what data is
   * available to the caller:
   * Method 1:
   * a = text1, b = text2
   * Method 2:
   * a = diffs
   * Method 3 (optimal):
   * a = text1, b = diffs
   * Method 4 (deprecated, use method 3):
   * a = text1, b = text2, c = diffs
   *
   * @param {string|!Array.<!diff_match_patch.Diff>} a text1 (methods 1,3,4) or
   * Array of diff tuples for text1 to text2 (method 2).
   * @param {string|!Array.<!diff_match_patch.Diff>} opt_b text2 (methods 1,4) or
   * Array of diff tuples for text1 to text2 (method 3) or undefined (method 2).
   * @param {string|!Array.<!diff_match_patch.Diff>} opt_c Array of diff tuples
   * for text1 to text2 (method 4) or undefined (methods 1,2,3).
   * @return {!Array.<!diff_match_patch.patch_obj>} Array of Patch objects.
   */
  //NOTE(hx): this is a bit problematic (either types / casts)
  function patch_make(a, opt_b, opt_c) {
    throw("not ready yet!!");
    var text1:SString, diffs:Diff;
    if (Std.is(a, String) && Std.is(opt_b, String) &&
        opt_c == null) {
      // Method 1: text1, text2
      // Compute diffs from text1 and text2.
      text1 = /** @type {string} */(cast a);
      diffs = this.diff_main(text1, /** @type {string} */(opt_b : SString), true);
      if (diffs.length > 2) {
        this.diff_cleanupSemantic(diffs);
        this.diff_cleanupEfficiency(diffs);
      }
    } else if (a != null && Std.is(a, Diff) && opt_b == null &&
        opt_c == null) {
      // Method 2: diffs
      // Compute text1 from diffs.
      //NOTE(hx): recheck this as is seems to be problematic
      diffs = /** @type {!Array.<!diff_match_patch.Diff>} */(cast a);
      text1 = this.diff_text1(diffs);
    } else if (Std.is(a, String) && opt_b != null && Std.is(opt_b, Diff) &&
        opt_c == null) {
      // Method 3: text1, diffs
      text1 = /** @type {string} */(cast a);
      diffs = /** @type {!Array.<!diff_match_patch.Diff>} */(cast opt_b);
    } else if (Std.is(a, String) && Std.is(opt_b, String) &&
        opt_c != null && Std.is(opt_c, Diff)) {
      // Method 4: text1, text2, diffs
      // text2 is not used.
      text1 = /** @type {string} */(cast a);
      diffs = /** @type {!Array.<!diff_match_patch.Diff>} */(cast opt_c);
    } else {
      throw new Error('Unknown call format to patch_make.');
    }

    if (diffs.length == 0) {
      return [];  // Get rid of the null case.
    }
    var patches = [];
    var patch = new PatchObj();
    var patchDiffLength = 0;  // Keeping our own length var is faster in JS.
    var char_count1 = 0;  // Number of characters into the text1 string.
    var char_count2 = 0;  // Number of characters into the text2 string.
    // Start with text1 (prepatch_text) and apply the diffs until we arrive at
    // text2 (postpatch_text).  We recreate the patches one by one to determine
    // context info.
    var prepatch_text:SString = text1;
    var postpatch_text:SString = text1;
    for (x in 0...diffs.length) {
      var diff_type = diffs[x][0];
      var diff_text:SString = diffs[x][1];

      if (patchDiffLength == 0 && diff_type != DIFF_EQUAL) {
        // A new patch starts here.
        patch.start1 = char_count1;
        patch.start2 = char_count2;
      }

      switch (diff_type) {
        case DIFF_INSERT:
          patch.diffs[patchDiffLength++] = diffs[x];
          patch.length2 += diff_text.length;
          postpatch_text = postpatch_text.substring(0, char_count2) + diff_text +
                           postpatch_text.substring(char_count2);
          //break;
        case DIFF_DELETE:
          patch.length1 += diff_text.length;
          patch.diffs[patchDiffLength++] = diffs[x];
          postpatch_text = postpatch_text.substring(0, char_count2) +
                           postpatch_text.substring(char_count2 +
                               diff_text.length);
          //break;
        case DIFF_EQUAL:
          //NOTE(hx): double check
          if ((diff_text.length <= 2).boolAsInt() * this.Patch_Margin != 0 &&
              patchDiffLength != 0 && diffs.length != x + 1) {
            // Small equality inside a patch.
            patch.diffs[patchDiffLength++] = diffs[x];
            patch.length1 += diff_text.length;
            patch.length2 += diff_text.length;
          } else if (diff_text.length >= 2 * this.Patch_Margin) {
            // Time for a new patch.
            if (patchDiffLength != 0) {
              this.patch_addContext_(patch, prepatch_text);
              patches.push(patch);
              patch = new PatchObj();
              patchDiffLength = 0;
              // Unlike Unidiff, our patch lists have a rolling context.
              // http://code.google.com/p/google-diff-match-patch/wiki/Unidiff
              // Update prepatch text & pos to reflect the application of the
              // just completed patch.
              prepatch_text = postpatch_text;
              char_count1 = char_count2;
            }
          }
          //break;
      }

      // Update the current character count.
      if (diff_type != DIFF_INSERT) {
        char_count1 += diff_text.length;
      }
      if (diff_type != DIFF_DELETE) {
        char_count2 += diff_text.length;
      }
    }
    // Pick up the leftover patch if not empty.
    if (patchDiffLength != 0) {
      this.patch_addContext_(patch, prepatch_text);
      patches.push(patch);
    }

    return patches;
  };


  /**
   * Given an array of patches, return another array that is identical.
   * @param {!Array.<!diff_match_patch.patch_obj>} patches Array of Patch objects.
   * @return {!Array.<!diff_match_patch.patch_obj>} Array of Patch objects.
   */
  function patch_deepCopy(patches:Array<PatchObj>) {
    // Making deep copies is hard in JavaScript.
    var patchesCopy = [];
    for (x in 0...patches.length) {
      var patch = patches[x];
      var patchCopy = new PatchObj();
      patchCopy.diffs = [];
      for (y in 0...patch.diffs.length) {
        patchCopy.diffs[y] = patch.diffs[y].clone(); //NOTE(hx): presumably the slice here was to make a shallow copy
      }
      patchCopy.start1 = patch.start1;
      patchCopy.start2 = patch.start2;
      patchCopy.length1 = patch.length1;
      patchCopy.length2 = patch.length2;
      patchesCopy[x] = patchCopy;
    }
    return patchesCopy;
  };


  /**
   * Merge a set of patches onto the text.  Return a patched text, as well
   * as a list of true/false values indicating which patches were applied.
   * @param {!Array.<!diff_match_patch.patch_obj>} patches Array of Patch objects.
   * @param {string} text Old text.
   * @return {!Array.<string|!Array.<boolean>>} Two element Array, containing the
   *      new text and an array of boolean values.
   */
  //NOTE(hx): introduce new type MergePatch (might need to rename it later)
  function patch_apply(patches:Array<PatchObj>, text:SString):Array<MergePatch> {
    if (patches.length == 0) {
      return [new MergePatch(text, [])];
    }

    // Deep copy the patches so that no changes are made to originals.
    patches = this.patch_deepCopy(patches);

    var nullPadding = this.patch_addPadding(patches);
    text = nullPadding + text + nullPadding;

    this.patch_splitMax(patches);
    // delta keeps track of the offset between the expected and actual location
    // of the previous patch.  If there are patches expected at positions 10 and
    // 20, but the first patch was found at 12, delta is 2 and the second patch
    // has an effective expected position of 22.
    var delta = 0;
    var results = [];
    for (x in 0...patches.length) {
      var expected_loc = patches[x].start2 + delta;
      var text1 = this.diff_text1(patches[x].diffs);
      var start_loc;
      var end_loc = -1;
      if (text1.length > this.Match_MaxBits) {
        // patch_splitMax will only provide an oversized pattern in the case of
        // a monster delete.
        start_loc = this.match_main(text, text1.substring(0, this.Match_MaxBits),
                                    expected_loc);
        if (start_loc != -1) {
          end_loc = this.match_main(text,
              text1.substring(text1.length - this.Match_MaxBits),
              expected_loc + text1.length - this.Match_MaxBits);
          if (end_loc == -1 || start_loc >= end_loc) {
            // Can't find valid trailing context.  Drop this patch.
            start_loc = -1;
          }
        }
      } else {
        start_loc = this.match_main(text, text1, expected_loc);
      }
      if (start_loc == -1) {
        // No match found.  :(
        results[x] = false;
        // Subtract the delta for this failed patch from subsequent patches.
        delta -= patches[x].length2 - patches[x].length1;
      } else {
        // Found a match.  :)
        results[x] = true;
        delta = start_loc - expected_loc;
        var text2;
        if (end_loc == -1) {
          text2 = text.substring(start_loc, start_loc + text1.length);
        } else {
          text2 = text.substring(start_loc, end_loc + this.Match_MaxBits);
        }
        if (text1 == text2) {
          // Perfect match, just shove the replacement text in.
          text = text.substring(0, start_loc) +
                 this.diff_text2(patches[x].diffs) +
                 text.substring(start_loc + text1.length);
        } else {
          // Imperfect match.  Run a diff to get a framework of equivalent
          // indices.
          var diffs = this.diff_main(text1, text2, false);
          if (text1.length > this.Match_MaxBits &&
              this.diff_levenshtein(diffs) / text1.length >
              this.Patch_DeleteThreshold) {
            // The end points match, but the content is unacceptably bad.
            results[x] = false;
          } else {
            this.diff_cleanupSemanticLossless(diffs);
            var index1 = 0;
            var index2 = 0; //NOTE(hx): init
            for (y in 0...patches[x].diffs.length) {
              var mod = patches[x].diffs[y];
              if (mod[0] != DIFF_EQUAL) {
                index2 = this.diff_xIndex(diffs, index1);
              }
              if (mod[0] == DIFF_INSERT) {  // Insertion
                text = text.substring(0, start_loc + index2) + mod[1] +
                       text.substring(start_loc + index2);
              } else if (mod[0] == DIFF_DELETE) {  // Deletion
                text = text.substring(0, start_loc + index2) +
                       text.substring(start_loc + this.diff_xIndex(diffs,
                           index1 + mod[1].length));
              }
              if (mod[0] != DIFF_DELETE) {
                index1 += mod[1].length;
              }
            }
          }
        }
      }
    }
    // Strip the padding off.
    text = text.substring(nullPadding.length, text.length - nullPadding.length);
    return [new MergePatch(text, results)];
  };


  /**
   * Add some padding on text start and end so that edges can match something.
   * Intended to be called only from within patch_apply.
   * @param {!Array.<!diff_match_patch.patch_obj>} patches Array of Patch objects.
   * @return {string} The padding string added to each side.
   */
  function patch_addPadding(patches:Array<PatchObj>):SString {
    var paddingLength = this.Patch_Margin;
    var nullPadding = '';
    //NOTE(hx): <= in loop
    for (x in 1...paddingLength + 1) {
      nullPadding += SString.fromCharCode(x);
    }

    // Bump all the patches forward.
    for (x in 0...patches.length) {
      patches[x].start1 += paddingLength;
      patches[x].start2 += paddingLength;
    }

    // Add some padding on start of first diff.
    var patch = patches[0];
    var diffs = patch.diffs;
    if (diffs.length == 0 || diffs[0][0] != DIFF_EQUAL) {
      // Add nullPadding equality.
      diffs.unshift(new SingleDiff(DIFF_EQUAL, nullPadding));
      patch.start1 -= paddingLength;  // Should be 0.
      patch.start2 -= paddingLength;  // Should be 0.
      patch.length1 += paddingLength;
      patch.length2 += paddingLength;
    } else if (paddingLength > diffs[0][1].length) {
      // Grow first equality.
      var extraLength:Int = paddingLength - (diffs[0][1] : SString).length; //NOTE(hx): typing as string
      diffs[0][1] = nullPadding.substring(diffs[0][1].length) + diffs[0][1];
      patch.start1 -= extraLength;
      patch.start2 -= extraLength;
      patch.length1 += extraLength;
      patch.length2 += extraLength;
    }

    // Add some padding on end of last diff.
    patch = patches[patches.length - 1];
    diffs = patch.diffs;
    if (diffs.length == 0 || diffs[diffs.length - 1][0] != DIFF_EQUAL) {
      // Add nullPadding equality.
      diffs.push(new SingleDiff(DIFF_EQUAL, nullPadding));
      patch.length1 += paddingLength;
      patch.length2 += paddingLength;
    } else if (paddingLength > diffs[diffs.length - 1][1].length) {
      // Grow last equality.
      var extraLength = paddingLength - (diffs[diffs.length - 1][1] : SString).length; //NOTE(hx): typing as string
      diffs[diffs.length - 1][1] += nullPadding.substring(0, extraLength);
      patch.length1 += extraLength;
      patch.length2 += extraLength;
    }

    return nullPadding;
  };


  /**
   * Look through the patches and break up any which are longer than the maximum
   * limit of the match algorithm.
   * Intended to be called only from within patch_apply.
   * @param {!Array.<!diff_match_patch.patch_obj>} patches Array of Patch objects.
   */
  function patch_splitMax(patches:Array<PatchObj>) {
    var patch_size = this.Match_MaxBits;
    //NOTE(hx): loops with continue. Converted to while as loop variable is modified
    var x = 0;
    while (x < patches.length) {
      if (patches[x].length1 <= patch_size) {
        x++;
        continue;
      }
      var bigpatch = patches[x];
      // Remove the big old patch.
      patches.splice(x--, 1);
      var start1 = bigpatch.start1;
      var start2 = bigpatch.start2;
      var precontext = '';
      while (bigpatch.diffs.length != 0) {
        // Create one of several smaller patches.
        var patch = new PatchObj();
        var empty = true;
        patch.start1 = start1 - precontext.length;
        patch.start2 = start2 - precontext.length;
        if (precontext != '') {
          patch.length1 = patch.length2 = precontext.length;
          patch.diffs.push(new SingleDiff(DIFF_EQUAL, precontext));
        }
        while (bigpatch.diffs.length != 0 &&
               patch.length1 < patch_size - this.Patch_Margin) {
          var diff_type = bigpatch.diffs[0][0];
          var diff_text = (bigpatch.diffs[0][1] : SString); //NOTE(hx): forcing as SString
          if (diff_type == DIFF_INSERT) {
            // Insertions are harmless.
            patch.length2 += diff_text.length;
            start2 += diff_text.length;
            patch.diffs.push(bigpatch.diffs.shift());
            empty = false;
          } else if (diff_type == DIFF_DELETE && patch.diffs.length == 1 &&
                     patch.diffs[0][0] == DIFF_EQUAL &&
                     diff_text.length > 2 * patch_size) {
            // This is a large deletion.  Let it pass in one chunk.
            patch.length1 += diff_text.length;
            start1 += diff_text.length;
            empty = false;
            patch.diffs.push(new SingleDiff(diff_type, diff_text));
            bigpatch.diffs.shift();
          } else {
            // Deletion or equality.  Only take as much as we can stomach.
            diff_text = diff_text.substring(0,
                patch_size - patch.length1 - this.Patch_Margin);
            patch.length1 += diff_text.length;
            start1 += diff_text.length;
            if (diff_type == DIFF_EQUAL) {
              patch.length2 += diff_text.length;
              start2 += diff_text.length;
            } else {
              empty = false;
            }
            patch.diffs.push(new SingleDiff(diff_type, diff_text));
            if (diff_text == bigpatch.diffs[0][1]) {
              bigpatch.diffs.shift();
            } else {
              bigpatch.diffs[0][1] =
                  bigpatch.diffs[0][1].substring(diff_text.length);
            }
          }
        }
        // Compute the head context for the next patch.
        precontext = this.diff_text2(patch.diffs);
        precontext =
            precontext.substring(precontext.length - this.Patch_Margin);
        // Append the end context for this patch.
        var postcontext = this.diff_text1(bigpatch.diffs)
                              .substring(0, this.Patch_Margin);
        if (postcontext != '') {
          patch.length1 += postcontext.length;
          patch.length2 += postcontext.length;
          if (patch.diffs.length != 0 &&
              patch.diffs[patch.diffs.length - 1][0] == DIFF_EQUAL) {
            patch.diffs[patch.diffs.length - 1][1] += postcontext;
          } else {
            patch.diffs.push(new SingleDiff(DIFF_EQUAL, postcontext));
          }
        }
        if (!empty) {
          patches.spliceInsert(++x, 0, [patch]);
        }
      }
      
      x++;
    }
  };


  /**
   * Take a list of patches and return a textual representation.
   * @param {!Array.<!diff_match_patch.patch_obj>} patches Array of Patch objects.
   * @return {string} Text representation of patches.
   */
  function patch_toText(patches:Array<PatchObj>) {
    var text = [];
    for (x in 0...patches.length) {
      text[x] = patches[x];
    }
    return text.join('');
  };


  /**
   * Parse a textual representation of patches and return a list of Patch objects.
   * @param {string} textline Text representation of patches.
   * @return {!Array.<!diff_match_patch.patch_obj>} Array of Patch objects.
   * @throws {!Error} If invalid input.
   */
  function patch_fromText(textline:SString) {
    var patches = [];
    if (textline.isNullOrEmpty()) {
      return patches;
    }
    var text = textline.split('\n');
    var textPointer = 0;
    var patchHeader = ~/^@@ -(\d+),?(\d*) \+(\d+),?(\d*) @@$/;
    while (textPointer < text.length) {
      var m = patchHeader.match(text[textPointer]); //NOTE(hx): check regex matching/matches
      if (!m) {
        throw new Error('Invalid patch string: ' + text[textPointer]);
      }
      var patch = new PatchObj();
      patches.push(patch);
      patch.start1 = Std.parseInt(patchHeader.matched(1)/*, 10*/);
      if (patchHeader.matched(2) == '') {
        patch.start1--;
        patch.length1 = 1;
      } else if (patchHeader.matched(2) == '0') {
        patch.length1 = 0;
      } else {
        patch.start1--;
        patch.length1 = Std.parseInt(patchHeader.matched(2)/*, 10*/);
      }

      patch.start2 = Std.parseInt(patchHeader.matched(3)/*, 10*/);
      if (patchHeader.matched(4) == '') {
        patch.start2--;
        patch.length2 = 1;
      } else if (patchHeader.matched(4) == '0') {
        patch.length2 = 0;
      } else {
        patch.start2--;
        patch.length2 = Std.parseInt(patchHeader.matched(4)/*, 10*/);
      }
      textPointer++;

      while (textPointer < text.length) {
        var sign = text[textPointer].charAt(0);
        var line = "";
        try {
          line = StringTools.urlDecode(text[textPointer].substring(1)); //NOTE(hx): decodeURI -> urlDecode (throw? - move line outside)
        } catch (ex:Dynamic) {
          // Malformed URI sequence.
          throw new Error('Illegal escape in patch_fromText: ' + /*line*/text[textPointer].substring(1));
        }
        if (sign == '-') {
          // Deletion.
          patch.diffs.push(new SingleDiff(DIFF_DELETE, line));
        } else if (sign == '+') {
          // Insertion.
          patch.diffs.push(new SingleDiff(DIFF_INSERT, line));
        } else if (sign == ' ') {
          // Minor equality.
          patch.diffs.push(new SingleDiff(DIFF_EQUAL, line));
        } else if (sign == '@') {
          // Start of next patch.
          break;
        } else if (sign == '') {
          // Blank line?  Whatever.
        } else {
          // WTF?
          throw new Error('Invalid patch mode "' + sign + '" in: ' + line);
        }
        textPointer++;
      }
    }
    return patches;
  };


  //NOTE(hx): not sure if action is needed here (we'll see later)

  // Export these global variables so that they survive Google's JS compiler.
  // In a browser, 'this' will be 'window'.
  // Users of node.js should 'require' the uncompressed version since Google's
  // JS compiler may break the following exports for non-browser environments.
  /*
  this['diff_match_patch'] = diff_match_patch;
  this['DIFF_DELETE'] = DIFF_DELETE;
  this['DIFF_INSERT'] = DIFF_INSERT;
  this['DIFF_EQUAL'] = DIFF_EQUAL;
  */
}


/**
 * Class representing one patch operation.
 * @constructor
 */
class PatchObj {
  
  /** @type {!Array.<!diff_match_patch.Diff>} */
  public var diffs:Diff = [];
  /** @type {?number} */
  public var start1:Null<Int> = null;
  /** @type {?number} */
  public var start2:Null<Int> = null;
  /** @type {number} */
  public var length1:Int = 0;
  /** @type {number} */
  public var length2:Int = 0;
  
  public function new() {
  }


  /**
   * Emmulate GNU diff's format.
   * Header: @@ -382,8 +481,9 @@
   * Indicies are printed as 1-based, not 0-based.
   * @return {string} The GNU diff string.
   */
  //NOTE(hx): check int to str conversions
  function toString() {
    var coords1, coords2;
    if (this.length1 == 0) {
      coords1 = this.start1 + ',0';
    } else if (this.length1 == 1) {
      coords1 = '' + (this.start1 + 1);
    } else {
      coords1 = (this.start1 + 1) + ',' + this.length1;
    }
    if (this.length2 == 0) {
      coords2 = this.start2 + ',0';
    } else if (this.length2 == 1) {
      coords2 = '' + (this.start2 + 1);
    } else {
      coords2 = (this.start2 + 1) + ',' + this.length2;
    }
    var text = ['@@ -' + coords1 + ' +' + coords2 + ' @@\n'];
    var op = ''; //NOTE(hx): init
    // Escape the body of the patch with %xx notation.
    for (x in 0...this.diffs.length) {
      switch (this.diffs[x][0]) {
        case DIFF_INSERT:
          op = '+';
          //break;
        case DIFF_DELETE:
          op = '-';
          //break;
        case DIFF_EQUAL:
          op = ' ';
          //break;
      }
      text[x + 1] = op + StringTools.urlEncode(this.diffs[x][1]) + '\n'; //NOTE(hx): encodeURI -> urlEncode
    }
    return ~/%20/g.replace(text.join(''), ' ');
  };
}


class MergePatch {
  
  public var text:SString;
  public var boolValues:Array<Bool>;
  
  public function new(newText:String, boolValues:Array<Bool>):Void {
    this.text = newText;
    this.boolValues = boolValues;
  }
}

/**
 * The data structure representing a diff is an array of tuples:
 * [[DIFF_DELETE, 'Hello'], [DIFF_INSERT, 'Goodbye'], [DIFF_EQUAL, ' world.']]
 * which means: delete 'Hello', add 'Goodbye' and keep ' world.'
 */
@:native("Diff")
@:forward
@:forwardStatics
abstract Diff(Array<SingleDiff>) from Array<SingleDiff> to Array<SingleDiff> {
  public function toString() {
    return '[' + this.join(', ') + ']';
  }
}

@:native("SingleDiff")
abstract SingleDiff(SingleDiffData) from SingleDiffData {
  public function new(op:DiffOp, text:SString) {
    this = new SingleDiffData(op, text);
  }
  
  @:arrayAccess function get(idx:Int):Dynamic {
    if (idx == 0) return (this.op : DiffOp);
    if (idx == 1) return (this.text : SString);
    throw "invalid idx"; 
  }
  
  @:arrayAccess function set(idx:Int, value:Dynamic):Dynamic {
    if (idx == 0) return ((this.op = value) : DiffOp);
    if (idx == 1) return ((this.text = value) : SString);
    throw "invalid idx"; 
  }
  
  public function clone():SingleDiff {
    return new SingleDiff(this.op, this.text);
  }
  
  inline public function toString() {
    return this.toString();
  }
  
  @:from static function fromDynArray(dynArray:Array<Dynamic>):SingleDiff {
  #if debug
    if (dynArray.length != 2) throw 'dynArray must be of length 2, it was $dynArray';
  #end
    return new SingleDiff(dynArray[0], dynArray[1]);
  }
}

@:structInit
class SingleDiffData {
  public var op:DiffOp;
  public var text:SString;
  
  public function new(op:DiffOp, text:SString):Void {
  #if debug
    switch (op) {
      case DIFF_DELETE, DIFF_EQUAL, DIFF_INSERT:
      default:
        throw '`op` must be a valid DiffOp, it was $op';
    }
    if (!Std.is(text, String)) throw '`text` must be compatible with SString, it was $text';
  #end
    this.op = op;
    this.text = text;
  }
  
  public function toString() {
    return '[' + this.op + ',"' + this.text + '"]';
  }
}

@:enum abstract DiffOp(Int) {
  var DIFF_DELETE = -1;
  var DIFF_INSERT = 1;
  var DIFF_EQUAL = 0;
}


typedef LinesToCharsObj = {
  var chars1:SString;
  var chars2:SString;
  var lineArray:Array<SString>;
}

@:native("SString")
@:forward
@:forwardStatics
abstract SString(String) from String to String {
  inline public function new(s:String) {
    this = s;
  }
  
  @:op(A + B)
  static function add(a:SString, b:String):SString {
    /*var buf = new StringBuf();
    for (c in a.uIterator()) buf.uAddChar(c);
    for (c in b.uIterator()) buf.uAddChar(c);
    return buf.toString();*/
    return (a : String) + b;
  }
  
  public function toString() {
    return (this : String);
  }
  
  public var length(get, never):Int;
  function get_length():Int {
    //trace("len " + this.length + "/" + Unifill.uLength(this));
    return Unifill.uLength(this);
  }
  
  static public function fromCharCode(code:Int):SString {
    return CodePoint.fromInt(code);
  }
  
  public function substr(startIndex : Int, ?length : Int) : SString {
    return Unifill.uSubstr(this, startIndex, length);
  }
  
  public function substring(startIndex:Int, ?endIndex:Int):SString {
    return Unifill.uSubstring(this, startIndex, endIndex);
  }
 
  public function indexOf(value:SString, startIndex:Int = 0) {
    return Unifill.uIndexOf(this, value, startIndex);
  }
  
  public function split(delimiter:SString):Array<SString> {
    return Unifill.uSplit(this, delimiter);
  }
  
  public function charAt(i:Int):SString {
    //NOTE(hx): this is necessary for 'hitting end' test (involves diff_cleanupSemanticLossless), 
    //          as in js "".charAt(0) == "", while elsewhere results in an exception being thrown.
    //          Ooohh... you never stop learning: in js "123".charAt(-1) also equals "".
    //          This is also true when you go the other way ("123".charAt(12)), but it's too expensive
    //          to check for length in here.
    if (this == "" || i < 0) return "";
    return Unifill.uCharAt(this, i);
  }
  
  public function charCodeAt(i:Int):Int {
    return Unifill.uCharCodeAt(this, i);
  }
}


abstract Error(String) from String to String {
  inline public function new(s:String) {
    this = s;
  }
}


@:allow(DiffMatchPatch)
class Internal {
  //NOTE(hx): change here later
  static inline var NUMBER_MAX = 1.7976931348623157e+308;
  
  inline static function isNullOrEmpty(s:SString) {
    return s == null || s == '';
  }
  
  inline static function boolAsInt(b:Bool):Int {
    return (b ? 1 : 0);
  }
  
  //NOTE(hx): try to improve perf on this one
  static function spliceInsert<T>(array:Array<T>, start:Int, deleteCount:Int, insert:Array<T>) {
  #if debug
    if (start < 0) throw "Invalid indices";
  #end
    var deleted = array.splice(start, deleteCount);
    for (i in 0...insert.length) {
      array.insert(start + i, insert[i]);
    }
    return deleted;
  }
}

@:forward
abstract NullIntArray(Array<Null<Int>>) from Array<Null<Int>> {
  
  @:arrayAccess function get(idx:Int) {
  #if debug
    if (idx < 0 || idx >= this.length) throw "Out of bounds index.";
  #end
    return this[idx];
  }
  
  @:arrayAccess function set(idx:Int, value:Null<Int>) {
  #if debug
    if (idx < 0 || idx >= this.length) throw "Out of bounds index.";
    if (value == null) throw "setting null";
  #end
    return this[idx] = value;
  }
}