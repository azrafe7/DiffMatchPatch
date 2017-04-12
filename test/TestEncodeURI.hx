// Copyright 2008 the V8 project authors. All rights reserved.
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above
//       copyright notice, this list of conditions and the following
//       disclaimer in the documentation and/or other materials provided
//       with the distribution.
//     * Neither the name of Google Inc. nor the names of its
//       contributors may be used to endorse or promote products derived
//       from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

import DiffMatchPatch.Internal.*;
import DiffMatchPatch.SString;
import unifill.Unicode;
 
import buddy.BuddySuite;
import buddy.Buddy;
import buddy.SuitesRunner;
import utest.Assert.*;
import Helpers.*;

using unifill.Unifill;


// Tests of URI encoding and decoding.
//NOTE(hx): from https://chromium.googlesource.com/v8/v8.git/+/3.30.7/test/mjsunit/uri.js
class TestEncodeURI extends BuddySuite {
  
  public function new() {
    
    describe('Tests of URI encoding and decoding.', {
      it('Non-transformed chars.', {
      equals("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-_.!~*'();/?:@&=+$,#",
             encodeURI("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-_.!~*'();/?:@&=+$,#"));
      });
      
        var cc1  ;
        var s1   ;
        var cc2  ;
        var s2   ;
        var cc3  ;
        var s3   ;
        var cc4  ;
        var s4   ;
        var cc5  ;
        var s5   ;
        var cc6  ;
        var s6   ;
        var cc7  ;
        var s7   ;
        var cc8_1;
        var cc8_2;
        var cc8;
        var s8   ;
        var cc9_1;
        var cc9_2;
        var cc9;
        var s9   ;
        var cc10 ;
        var s10  ;
        
      it('Create strings from codepoints.', {
        cc1  = 0x007D;
        s1   = SString.fromCharCode(cc1);
        cc2  = 0x0000;
        s2   = SString.fromCharCode(cc2);
        cc3  = 0x0080;
        s3   = SString.fromCharCode(cc3);
        cc4  = 0x0555;
        s4   = SString.fromCharCode(cc4);
        cc5  = 0x07FF;
        s5   = SString.fromCharCode(cc5);
        cc6  = 0x0800;
        s6   = SString.fromCharCode(cc6);
        cc7  = 0xAEEE;
        s7   = SString.fromCharCode(cc7);
        cc8_1= 0xD800;
        cc8_2= 0xDC00;
        cc8  = Unicode.decodeSurrogate(cc8_1, cc8_2);
        //s8   = SString.fromCharCode(cc8_1) + SString.fromCharCode(cc8_2);
        s8   = SString.fromCharCode(cc8);
        cc9_1= 0xDBFF;
        cc9_2= 0xDFFF;
        cc9  = Unicode.decodeSurrogate(cc9_1, cc9_2);
        //s9   = SString.fromCharCode(cc9_1) + SString.fromCharCode(cc9_2);
        s9   = SString.fromCharCode(cc9);
        cc10 = 0xE000;
        s10  = SString.fromCharCode(cc10);
      });
      
      it('EncodeURI.', {
        equals('%7D', encodeURI(s1));
        equals('%00', encodeURI(s2));
        equals('%C2%80', encodeURI(s3));
        equals('%D5%95', encodeURI(s4));
        equals('%DF%BF', encodeURI(s5));
        equals('%E0%A0%80', encodeURI(s6));
        equals('%EA%BB%AE', encodeURI(s7));
        equals('%F0%90%80%80', encodeURI(s8));
        equals('%F4%8F%BF%BF', encodeURI(s9));
        equals('%EE%80%80', encodeURI(s10));
      });
      
      it('Encode and decode back.', {
        equals(cc1, decodeURI(encodeURI(s1)).charCodeAt(0));
        equals(cc2, decodeURI(encodeURI(s2)).charCodeAt(0));
        equals(cc3, decodeURI(encodeURI(s3)).charCodeAt(0));
        equals(cc4, decodeURI(encodeURI(s4)).charCodeAt(0));
        equals(cc5, decodeURI(encodeURI(s5)).charCodeAt(0));
        equals(cc6, decodeURI(encodeURI(s6)).charCodeAt(0));
        equals(cc7, decodeURI(encodeURI(s7)).charCodeAt(0));
        //equals(cc8_1, decodeURI(encodeURI(s8)).charCodeAt(0));
        //equals(cc8_2, decodeURI(encodeURI(s8)).charCodeAt(1));
        equals(cc8, decodeURI(encodeURI(s8)).charCodeAt(0));
        //equals(cc9_1, decodeURI(encodeURI(s9)).charCodeAt(0));
        //equals(cc9_2, decodeURI(encodeURI(s9)).charCodeAt(1));
        equals(cc9, decodeURI(encodeURI(s9)).charCodeAt(0));
        equals(cc10, decodeURI(encodeURI(s10)).charCodeAt(0));
      });
      
      it('Empty strings.', {
        equals("", decodeURI(""));
        equals("", encodeURI(""));
      });
      
      it('Input == Output.', {
        
        inline function test(string:SString) {
          equals(string, decodeURI(encodeURI(string)));
        }
        
        test("\u1234\u0123\uabcd");
        test("abcd");
        test("ab<\u1234\u0123");
        test("ab\u1234<\u0123");
      });
    });
  }
}
