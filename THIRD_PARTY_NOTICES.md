# Third-party notices

The app contains no third-party libraries. The filter engine in
`Packages/JQEngine` is a Swift implementation of the jq language written for
this project, and it uses material from jq as listed below.

## jq

- `Packages/JQEngine/Sources/JQEngine/Compiler/Prelude.swift` adapts the
  builtin definitions in jq 1.7.1's `src/builtin.jq`. This is compiled into
  the app, and the About screen shows the notice below (design R9.14).
- `Packages/JQEngine/Tests/JQEngineTests/Fixtures/Sources/jq.test`,
  `onig.test` and `base64.test` are jq 1.7.1's test files.
  `Fixtures/jq-1.7.1.json` records jq 1.7.1's output for them and for the
  manual's examples below. These are used only by the tests.

Source: https://github.com/jqlang/jq

```
jq is copyright (C) 2012 Stephen Dolan

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

## The jq manual

`Fixtures/Sources/man.test` and `manonig.test` are jq 1.7.1's
`tests/man.test` and `tests/manonig.test`, which jq generates from the
examples in its manual. The manual is by the jq authors and licensed under
Creative Commons Attribution 3.0 (https://creativecommons.org/licenses/by/3.0/).
The files are used unchanged, by the tests only, and are not part of the app.

The app's cheat sheet, presets, sample input and gallery examples
(`App/Resources`) were written for this project.
