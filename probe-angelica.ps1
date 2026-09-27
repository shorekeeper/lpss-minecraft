#Requires -Version 7.0
<#
    Reads the Iris fork inside the Angelica jar.

    A shader pack is written against whatever the loader parses: which
    programs it looks for, which shaders.properties keys it honours, which
    uniforms it uploads, which feature flags it accepts, which texture formats
    it knows, and how it rewrites #version. None of that is documented for the
    fork, but all of it sits in the class files as plain constant pool strings
    and enum fields, so this walks them without running anything.

    Modes:
      default                 the full survey; paste its output back
      -Class name             dump one class
      -Class n -Method m      disassemble one method
      -Grep text              list classes whose constant pool holds the text
      -Report path            also write everything to a file
#>
[CmdletBinding()]
param(
    [string] $Jar = '',
    [string] $Mods = '',
    [string] $Class = '',
    [string] $Method = '',
    [string] $Grep = '',
    [string] $Report = '',
    [switch] $Full
)

$ErrorActionPreference = 'Stop'

if (-not $Jar) {
    $dirs = @()
    if ($Mods) { $dirs += $Mods }
    $dirs += (Join-Path (Get-Location).Path 'mods')
    $dirs += (Get-Location).Path
    foreach ($d in $dirs) {
        $found = Get-ChildItem $d -Filter 'angelica*.jar' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($found) { $Jar = $found.FullName; break }
    }
    if (-not $Jar) {
        Write-Host 'no angelica*.jar found; pass -Jar or -Mods' -ForegroundColor Red
        exit 1
    }
}

function Say { param($k, $t, $c = 'Gray') Write-Host ("{0,-11} {1}" -f $k, $t) -ForegroundColor $c }
function Head { param($t) Write-Host ''; Write-Host $t -ForegroundColor White }

# ---------------------------------------------------------------- reader

function Get-U1 {
    param([byte[]] $B, [ref] $P)
    $v = $B[$P.Value]
    $P.Value = $P.Value + 1
    return [int] $v
}

function Get-U2 {
    param([byte[]] $B, [ref] $P)
    $v = ([int]$B[$P.Value] -shl 8) -bor [int]$B[$P.Value + 1]
    $P.Value = $P.Value + 2
    return $v
}

function Get-U4 {
    param([byte[]] $B, [ref] $P)
    $v = 0L
    for ($k = 0; $k -lt 4; $k++) { $v = ($v -shl 8) -bor [long]$B[$P.Value + $k] }
    $P.Value = $P.Value + 4
    return $v
}

function Read-Pool {
    param([byte[]] $B, [ref] $P)

    $count = Get-U2 $B $P
    $pool = New-Object object[] $count
    $i = 1

    while ($i -lt $count) {
        $tag = Get-U1 $B $P
        switch ($tag) {
            1 {
                $len = Get-U2 $B $P
                $s = [System.Text.Encoding]::UTF8.GetString($B, $P.Value, $len)
                $P.Value = $P.Value + $len
                $pool[$i] = @{ Tag = 1; Utf8 = $s }
            }
            3 { $pool[$i] = @{ Tag = 3; Num = (Get-U4 $B $P) } }
            4 { $null = Get-U4 $B $P; $pool[$i] = @{ Tag = 4 } }
            5 {
                $hi = Get-U4 $B $P
                $lo = Get-U4 $B $P
                $pool[$i] = @{ Tag = 5; Num = (($hi -shl 32) -bor $lo) }
                $i++
            }
            6 { $null = Get-U4 $B $P; $null = Get-U4 $B $P; $pool[$i] = @{ Tag = 6 }; $i++ }
            7 { $pool[$i] = @{ Tag = 7; NameIndex = (Get-U2 $B $P) } }
            8 { $pool[$i] = @{ Tag = 8; NameIndex = (Get-U2 $B $P) } }
            9  { $c = Get-U2 $B $P; $n = Get-U2 $B $P; $pool[$i] = @{ Tag = 9;  ClassIndex = $c; NatIndex = $n } }
            10 { $c = Get-U2 $B $P; $n = Get-U2 $B $P; $pool[$i] = @{ Tag = 10; ClassIndex = $c; NatIndex = $n } }
            11 { $c = Get-U2 $B $P; $n = Get-U2 $B $P; $pool[$i] = @{ Tag = 11; ClassIndex = $c; NatIndex = $n } }
            12 { $n = Get-U2 $B $P; $d = Get-U2 $B $P; $pool[$i] = @{ Tag = 12; NameIndex = $n; DescIndex = $d } }
            15 { $null = Get-U1 $B $P; $null = Get-U2 $B $P; $pool[$i] = @{ Tag = 15 } }
            16 { $null = Get-U2 $B $P; $pool[$i] = @{ Tag = 16 } }
            17 { $null = Get-U4 $B $P; $pool[$i] = @{ Tag = 17 } }
            18 { $n = Get-U2 $B $P; $d = Get-U2 $B $P; $pool[$i] = @{ Tag = 18; NatIndex = $d } }
            19 { $null = Get-U2 $B $P; $pool[$i] = @{ Tag = 19 } }
            20 { $null = Get-U2 $B $P; $pool[$i] = @{ Tag = 20 } }
            default { throw "unknown constant tag $tag at index $i" }
        }
        $i++
    }
    return $pool
}

function Get-Utf8 {
    param($Pool, [int] $Index)
    if ($Index -le 0 -or $Index -ge $Pool.Length) { return '' }
    $e = $Pool[$Index]
    if ($null -eq $e -or $e.Tag -ne 1) { return '' }
    return $e.Utf8
}

function Get-ClassName {
    param($Pool, [int] $Index)
    if ($Index -le 0 -or $Index -ge $Pool.Length) { return '' }
    $e = $Pool[$Index]
    if ($null -eq $e -or $e.Tag -ne 7) { return '' }
    return Get-Utf8 $Pool $e.NameIndex
}

function Get-ConstText {
    param($Pool, [int] $Index)
    if ($Index -le 0 -or $Index -ge $Pool.Length) { return "#$Index" }
    $e = $Pool[$Index]
    if ($null -eq $e) { return "#$Index" }

    switch ($e.Tag) {
        1 { return $e.Utf8 }
        3 { return ("{0}  0x{0:x}" -f $e.Num) }
        5 { return ("{0}  0x{0:x}" -f $e.Num) }
        7 { return (Get-Utf8 $Pool $e.NameIndex) }
        8 { return ('"' + (Get-Utf8 $Pool $e.NameIndex) + '"') }
        { $_ -in 9, 10, 11 } {
            $cn = Get-ClassName $Pool $e.ClassIndex
            $nat = $Pool[$e.NatIndex]
            if ($null -eq $nat) { return $cn }
            $n = Get-Utf8 $Pool $nat.NameIndex
            $d = Get-Utf8 $Pool $nat.DescIndex
            return ("{0}.{1} {2}" -f $cn, $n, $d)
        }
        12 {
            $n = Get-Utf8 $Pool $e.NameIndex
            $d = Get-Utf8 $Pool $e.DescIndex
            return ("{0} {1}" -f $n, $d)
        }
        18 {
            $nat = $Pool[$e.NatIndex]
            if ($null -eq $nat) { return 'invokedynamic' }
            return (Get-Utf8 $Pool $nat.NameIndex)
        }
        default { return ("#{0} tag {1}" -f $Index, $e.Tag) }
    }
}

# ---------------------------------------------------------------- members

function Read-Member {
    param([byte[]] $B, [ref] $P, $Pool, [switch] $WithCode)

    $access = Get-U2 $B $P
    $name = Get-Utf8 $Pool (Get-U2 $B $P)
    $desc = Get-Utf8 $Pool (Get-U2 $B $P)
    $attrs = Get-U2 $B $P
    $value = $null
    $code = $null

    for ($a = 0; $a -lt $attrs; $a++) {
        $an = Get-Utf8 $Pool (Get-U2 $B $P)
        $len = [int](Get-U4 $B $P)
        $end = $P.Value + $len

        if ($an -eq 'ConstantValue' -and $len -eq 2) {
            $vi = Get-U2 $B $P
            $ve = if ($vi -gt 0 -and $vi -lt $Pool.Length) { $Pool[$vi] } else { $null }
            if ($null -ne $ve) {
                if ($ve.Tag -eq 3 -or $ve.Tag -eq 5) { $value = $ve.Num }
                elseif ($ve.Tag -eq 8) { $value = Get-Utf8 $Pool $ve.NameIndex }
            }
        } elseif ($an -eq 'Code' -and $WithCode) {
            $null = Get-U2 $B $P
            $null = Get-U2 $B $P
            $clen = [int](Get-U4 $B $P)
            $code = New-Object byte[] $clen
            [Array]::Copy($B, $P.Value, $code, 0, $clen)
        }
        $P.Value = $end
    }

    return [pscustomobject]@{
        Access = $access
        Name = $name
        Descriptor = $desc
        Value = $value
        Code = $code
        Static = (($access -band 0x0008) -ne 0)
    }
}

function Read-ClassFile {
    param([byte[]] $B, [switch] $WithCode)

    if ($B.Length -lt 10) { return $null }
    if ($B[0] -ne 0xCA -or $B[1] -ne 0xFE -or $B[2] -ne 0xBA -or $B[3] -ne 0xBE) { return $null }

    $p = 8
    $pool = Read-Pool $B ([ref]$p)

    $null = Get-U2 $B ([ref]$p)
    $thisName = Get-ClassName $pool (Get-U2 $B ([ref]$p))
    $superName = Get-ClassName $pool (Get-U2 $B ([ref]$p))

    $ifCount = Get-U2 $B ([ref]$p)
    $interfaces = @()
    for ($k = 0; $k -lt $ifCount; $k++) { $interfaces += Get-ClassName $pool (Get-U2 $B ([ref]$p)) }

    $fieldCount = Get-U2 $B ([ref]$p)
    $fields = @()
    for ($k = 0; $k -lt $fieldCount; $k++) { $fields += Read-Member $B ([ref]$p) $pool }

    $methodCount = Get-U2 $B ([ref]$p)
    $methods = @()
    for ($k = 0; $k -lt $methodCount; $k++) {
        $methods += Read-Member $B ([ref]$p) $pool -WithCode:$WithCode
    }

    return [pscustomobject]@{
        Pool = $pool
        Name = $thisName
        Super = $superName
        Interfaces = $interfaces
        Fields = $fields
        Methods = $methods
    }
}

# Enum constants are the static fields typed as the enum itself. That is how
# FeatureFlags, ProgramId and the texture format list are declared.
function Get-EnumConstants {
    param($Parsed)
    $self = 'L' + $Parsed.Name + ';'
    return @($Parsed.Fields | Where-Object { $_.Static -and $_.Descriptor -eq $self } | ForEach-Object Name)
}

# Every string literal a class can load.
function Get-Strings {
    param($Parsed)
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($e in $Parsed.Pool) {
        if ($null -eq $e -or $e.Tag -ne 8) { continue }
        $s = Get-Utf8 $Parsed.Pool $e.NameIndex
        if ($s.Length -ge 1) { $out.Add($s) }
    }
    return $out
}

# ---------------------------------------------------------------- bytecode

function New-OpcodeLengths {
    $len = New-Object int[] 256
    for ($i = 0; $i -lt 256; $i++) { $len[$i] = -1 }
    foreach ($r in @(@(0x00, 0x0f), @(0x1a, 0x35), @(0x3b, 0x83), @(0x85, 0x98),
                     @(0xac, 0xb1), @(0xbe, 0xbf), @(0xc2, 0xc3))) {
        for ($i = $r[0]; $i -le $r[1]; $i++) { $len[$i] = 0 }
    }
    $len[0x10] = 1; $len[0x11] = 2
    $len[0x12] = 1; $len[0x13] = 2; $len[0x14] = 2
    for ($i = 0x15; $i -le 0x19; $i++) { $len[$i] = 1 }
    for ($i = 0x36; $i -le 0x3a; $i++) { $len[$i] = 1 }
    $len[0x84] = 2
    for ($i = 0x99; $i -le 0xa8; $i++) { $len[$i] = 2 }
    $len[0xa9] = 1
    for ($i = 0xb2; $i -le 0xb8; $i++) { $len[$i] = 2 }
    $len[0xb9] = 4; $len[0xba] = 4
    $len[0xbb] = 2; $len[0xbc] = 1; $len[0xbd] = 2
    $len[0xc0] = 2; $len[0xc1] = 2
    $len[0xc5] = 3
    $len[0xc6] = 2; $len[0xc7] = 2
    $len[0xc8] = 4; $len[0xc9] = 4
    return $len
}

function New-OpcodeNames {
    $n = @{}
    $n[0x00] = 'nop'; $n[0x01] = 'aconst_null'
    for ($i = 0; $i -le 5; $i++) { $n[0x03 + $i] = "iconst_$i" }
    $n[0x02] = 'iconst_m1'
    $n[0x09] = 'lconst_0'; $n[0x0a] = 'lconst_1'
    $n[0x10] = 'bipush'; $n[0x11] = 'sipush'
    $n[0x12] = 'ldc'; $n[0x13] = 'ldc_w'; $n[0x14] = 'ldc2_w'
    $n[0x15] = 'iload'; $n[0x16] = 'lload'; $n[0x19] = 'aload'
    for ($i = 0; $i -le 3; $i++) {
        $n[0x1a + $i] = "iload_$i"; $n[0x1e + $i] = "lload_$i"; $n[0x2a + $i] = "aload_$i"
        $n[0x3b + $i] = "istore_$i"; $n[0x3f + $i] = "lstore_$i"; $n[0x4b + $i] = "astore_$i"
    }
    $n[0x36] = 'istore'; $n[0x37] = 'lstore'; $n[0x3a] = 'astore'
    $n[0x57] = 'pop'; $n[0x59] = 'dup'
    $n[0x60] = 'iadd'; $n[0x61] = 'ladd'; $n[0x64] = 'isub'; $n[0x65] = 'lsub'
    $n[0x68] = 'imul'; $n[0x69] = 'lmul'; $n[0x78] = 'ishl'; $n[0x79] = 'lshl'
    $n[0x7e] = 'iand'; $n[0x7f] = 'land'; $n[0x80] = 'ior'; $n[0x81] = 'lor'
    $n[0x85] = 'i2l'; $n[0x88] = 'l2i'; $n[0x94] = 'lcmp'
    $n[0x99] = 'ifeq'; $n[0x9a] = 'ifne'; $n[0xa7] = 'goto'
    $n[0xac] = 'ireturn'; $n[0xad] = 'lreturn'; $n[0xb0] = 'areturn'; $n[0xb1] = 'return'
    $n[0xb2] = 'getstatic'; $n[0xb3] = 'putstatic'; $n[0xb4] = 'getfield'; $n[0xb5] = 'putfield'
    $n[0xb6] = 'invokevirtual'; $n[0xb7] = 'invokespecial'; $n[0xb8] = 'invokestatic'
    $n[0xb9] = 'invokeinterface'; $n[0xba] = 'invokedynamic'
    $n[0xbb] = 'new'; $n[0xc0] = 'checkcast'
    $n[0xaa] = 'tableswitch'; $n[0xab] = 'lookupswitch'; $n[0xc4] = 'wide'
    return $n
}

$script:OpLen = New-OpcodeLengths
$script:OpName = New-OpcodeNames

function Show-Code {
    param($Pool, [byte[]] $Code, [string] $Title)

    Say 'code' $Title 'White'
    if ($null -eq $Code) {
        Say '' '  no code attribute, abstract or native' 'DarkYellow'
        return
    }

    $pc = 0
    while ($pc -lt $Code.Length) {
        $op = [int] $Code[$pc]
        $name = if ($script:OpName.ContainsKey($op)) { $script:OpName[$op] } else { ('0x{0:x2}' -f $op) }
        $operandText = ''
        $size = $script:OpLen[$op]

        if ($op -eq 0xaa -or $op -eq 0xab) {
            $at = $pc + 1
            while ($at % 4 -ne 0) { $at++ }
            if ($op -eq 0xaa) {
                $low = 0L; $high = 0L
                for ($k = 0; $k -lt 4; $k++) { $low = ($low -shl 8) -bor [long]$Code[$at + 4 + $k] }
                for ($k = 0; $k -lt 4; $k++) { $high = ($high -shl 8) -bor [long]$Code[$at + 8 + $k] }
                $size = ($at + 12 + ($high - $low + 1) * 4) - $pc - 1
            } else {
                $pairs = 0L
                for ($k = 0; $k -lt 4; $k++) { $pairs = ($pairs -shl 8) -bor [long]$Code[$at + 4 + $k] }
                $size = ($at + 8 + $pairs * 8) - $pc - 1
            }
        } elseif ($op -eq 0xc4) {
            $inner = [int] $Code[$pc + 1]
            $size = if ($inner -eq 0x84) { 5 } else { 3 }
        } elseif ($size -lt 0) {
            Say '' ("  {0,4}  {1}  unknown opcode, stopping" -f $pc, $name) 'Red'
            return
        }

        if ($op -eq 0x12) {
            $operandText = Get-ConstText $Pool ([int]$Code[$pc + 1])
        } elseif ($op -in 0x13, 0x14, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xbb, 0xc0) {
            $idx = ([int]$Code[$pc + 1] -shl 8) -bor [int]$Code[$pc + 2]
            $operandText = Get-ConstText $Pool $idx
        } elseif ($op -eq 0x10) {
            $operandText = [string]([sbyte]$Code[$pc + 1])
        } elseif ($op -eq 0x11) {
            $v = ([int]$Code[$pc + 1] -shl 8) -bor [int]$Code[$pc + 2]
            if ($v -ge 0x8000) { $v = $v - 0x10000 }
            $operandText = ("{0}  0x{0:x}" -f $v)
        }

        Say '' ("  {0,4}  {1,-16} {2}" -f $pc, $name, $operandText) 'Cyan'
        $pc = $pc + 1 + [int]$size
    }
}

# ---------------------------------------------------------------- archive

Add-Type -AssemblyName System.IO.Compression.FileSystem

function Read-Entry {
    param($Entry)
    $stream = $Entry.Open()
    try {
        $buffer = [System.IO.MemoryStream]::new()
        $stream.CopyTo($buffer)
        return $buffer.ToArray()
    } finally { $stream.Dispose() }
}

function Read-Text {
    param($Entry)
    return [System.Text.Encoding]::UTF8.GetString((Read-Entry $Entry))
}

$opened = [System.Collections.Generic.List[object]]::new()
if ($Report) { Start-Transcript -Path $Report -Force | Out-Null }

try {
    Say 'jar' ("{0}  ({1:n1} MB)" -f (Split-Path $Jar -Leaf), ((Get-Item $Jar).Length / 1MB)) 'Green'

    $outer = [System.IO.Compression.ZipFile]::OpenRead($Jar)
    $opened.Add($outer)

    $all = [System.Collections.Generic.List[object]]::new()
    foreach ($e in $outer.Entries) { $all.Add($e) }

    foreach ($n in ($outer.Entries | Where-Object { $_.FullName -like '*.jar' })) {
        $temp = Join-Path $env:TEMP ("angelica-probe-{0}" -f (Split-Path $n.FullName -Leaf))
        [System.IO.File]::WriteAllBytes($temp, (Read-Entry $n))
        $inner = [System.IO.Compression.ZipFile]::OpenRead($temp)
        $opened.Add($inner)
        foreach ($e in $inner.Entries) { $all.Add($e) }
        Say 'nested' $n.FullName 'DarkGray'
    }

    $classes = @($all | Where-Object { $_.FullName -like '*.class' })
    Say 'classes' $classes.Count 'DarkGray'

    # The survey only cares about the shader side. Narrowing the scan set by
    # path keeps every full-jar text scan to a few seconds.
    $shaderClasses = @($classes | Where-Object { $_.FullName -match '(?i)iris|shader|glsl|angelica/(compat|glsm|render)' })
    if ($shaderClasses.Count -eq 0) { $shaderClasses = $classes }
    Say 'scanned' ("{0} shader-side classes" -f $shaderClasses.Count) 'DarkGray'

    function Select-ByText {
        param([string] $Pattern, $Set = $shaderClasses)
        $hits = [System.Collections.Generic.List[object]]::new()
        foreach ($entry in $Set) {
            $bytes = Read-Entry $entry
            $ascii = [System.Text.Encoding]::ASCII.GetString($bytes)
            if ($ascii -match $Pattern) {
                $hits.Add([pscustomobject]@{ Entry = $entry; Bytes = $bytes })
            }
        }
        return $hits
    }

    # Simple name match, any package: the fork may live under net/coderbot,
    # net/irisshaders or something of Angelica's own.
    function Find-Class {
        param([string] $Simple)
        return @($classes | Where-Object { $_.FullName -like "*/$Simple.class" -or $_.FullName -eq "$Simple.class" })
    }

    function Show-Class {
        param($Parsed, [switch] $Brief)

        Say 'class' $Parsed.Name 'Green'
        Say 'extends' $Parsed.Super 'DarkGray'
        foreach ($i in $Parsed.Interfaces) { Say 'implements' $i 'DarkGray' }

        $enums = Get-EnumConstants $Parsed
        if ($enums.Count -gt 0) {
            Write-Host ''
            Say 'enum' '' 'White'
            foreach ($n in $enums) { Say '' ("  " + $n) 'Cyan' }
        }

        $consts = $Parsed.Fields | Where-Object { $null -ne $_.Value }
        if ($consts) {
            Write-Host ''
            Say 'constants' '' 'White'
            foreach ($f in $consts) {
                if ($f.Value -is [long] -or $f.Value -is [int]) {
                    Say '' ("  {0,-34} {1,20}  0x{1:x}" -f $f.Name, $f.Value) 'Cyan'
                } else {
                    Say '' ("  {0,-34} {1}" -f $f.Name, $f.Value) 'Cyan'
                }
            }
        }

        if (-not $Brief) {
            Write-Host ''
            Say 'fields' '' 'White'
            foreach ($f in $Parsed.Fields) { Say '' ("  {0,-34} {1}" -f $f.Name, $f.Descriptor) 'DarkGray' }

            Write-Host ''
            Say 'methods' '' 'White'
            foreach ($m in $Parsed.Methods) { Say '' ("  {0,-34} {1}" -f $m.Name, $m.Descriptor) 'DarkGray' }

            Write-Host ''
            Say 'strings' '' 'White'
            foreach ($s in (Get-Strings $Parsed)) { Say '' ("  " + $s) 'DarkGray' }
        }
    }

    function Show-Methods {
        param($Parsed, [string] $Pattern)
        foreach ($m in $Parsed.Methods) {
            if ($m.Name -notmatch $Pattern) { continue }
            Write-Host ''
            Show-Code $Parsed.Pool $m.Code ("{0}.{1} {2}" -f $Parsed.Name, $m.Name, $m.Descriptor)
        }
    }

    # Prints the strings of every class with the given simple name, filtered.
    function Show-StringsOf {
        param([string] $Simple, [string] $Filter = '.', [switch] $Sorted)
        $hits = Find-Class $Simple
        if ($hits.Count -eq 0) { Say 'absent' $Simple 'DarkYellow'; return }
        foreach ($h in $hits) {
            $parsed = Read-ClassFile (Read-Entry $h)
            if ($null -eq $parsed) { continue }
            Say 'class' $parsed.Name 'Green'
            $strings = @(Get-Strings $parsed | Where-Object { $_ -match $Filter } | Select-Object -Unique)
            if ($Sorted) { $strings = @($strings | Sort-Object) }
            foreach ($s in $strings) { Say '' ("  " + $s) 'Cyan' }
        }
    }

    function Show-EnumOf {
        param([string] $Simple)
        $hits = Find-Class $Simple
        if ($hits.Count -eq 0) { Say 'absent' $Simple 'DarkYellow'; return }
        foreach ($h in $hits) {
            $parsed = Read-ClassFile (Read-Entry $h)
            if ($null -eq $parsed) { continue }
            Say 'class' $parsed.Name 'Green'
            foreach ($n in (Get-EnumConstants $parsed)) { Say '' ("  " + $n) 'Cyan' }
        }
    }

    # ------------------------------------------------------------ modes

    if ($Class) {
        $hit = $classes | Where-Object { $_.FullName -like "*$Class*" } | Select-Object -First 1
        if (-not $hit) { Say 'absent' "no class matching $Class" 'Red'; exit 1 }
        $parsed = Read-ClassFile (Read-Entry $hit) -WithCode

        if ($Method) {
            Head 'method'
            Say 'class' $parsed.Name 'Green'
            Show-Methods $parsed $Method
        } else {
            Head 'class dump'
            Show-Class $parsed
        }
        exit 0
    }

    if ($Grep) {
        Head "classes mentioning $Grep"
        foreach ($h in (Select-ByText $Grep $classes)) {
            $parsed = Read-ClassFile $h.Bytes
            if ($null -eq $parsed) { continue }
            Say '' ("  " + $parsed.Name) 'Cyan'
            if ($Full) {
                foreach ($e in $parsed.Pool) {
                    if ($null -eq $e -or $e.Tag -ne 1) { continue }
                    if ($e.Utf8 -match $Grep) { Say '' ("      " + $e.Utf8) 'DarkGray' }
                }
            }
        }
        exit 0
    }

    # ------------------------------------------------------------ survey

    Head '0. versions'
    foreach ($name in @('META-INF/MANIFEST.MF', 'mcmod.info', 'META-INF/mods.toml')) {
        $e = $all | Where-Object { $_.FullName -eq $name } | Select-Object -First 1
        if (-not $e) { continue }
        Say 'file' $name 'Green'
        foreach ($line in ((Read-Text $e) -split "`n")) {
            if ($line -match '(?i)version|iris|sodium|lwjgl') { Say '' ("  " + $line.Trim()) 'Cyan' }
        }
    }
    foreach ($h in (Find-Class 'Iris')) {
        $parsed = Read-ClassFile (Read-Entry $h)
        if ($null -eq $parsed) { continue }
        Say 'class' $parsed.Name 'Green'
        foreach ($s in (Get-Strings $parsed | Where-Object { $_ -match '\d+\.\d+|version|Version' } | Select-Object -Unique)) {
            Say '' ("  " + $s) 'Cyan'
        }
    }

    Head '1. where the fork lives'
    Say 'why' 'the package tells which upstream generation was backported' 'DarkGray'
    $packages = @{}
    foreach ($c in $classes) {
        if ($c.FullName -notmatch '(?i)iris') { continue }
        $parts = $c.FullName -split '/'
        $depth = [Math]::Min(4, $parts.Count - 1)
        $key = ($parts[0..($depth - 1)] -join '/')
        if ($packages.ContainsKey($key)) { $packages[$key]++ } else { $packages[$key] = 1 }
    }
    foreach ($k in ($packages.Keys | Sort-Object)) { Say '' ("  {0,-56} {1,5}" -f $k, $packages[$k]) 'Cyan' }

    Head '2. feature flags'
    Say 'why' 'what a pack may request in shaders.properties iris.features.required' 'DarkGray'
    Show-EnumOf 'FeatureFlags'

    Head '3. programs'
    Say 'why' 'which .vsh/.fsh/.csh names the loader will look for' 'DarkGray'
    Show-EnumOf 'ProgramId'
    Show-EnumOf 'ProgramArrayId'
    Show-StringsOf 'ProgramSet' -Filter '^(gbuffers_|shadow|composite|deferred|final|prepare|begin|setup|shadowcomp|dh_)' -Sorted

    Head '4. shaders.properties keys'
    Show-StringsOf 'ShaderProperties' -Filter '^[a-zA-Z][\w.<>*]*$' -Sorted

    Head '5. const directives'
    Say 'why' 'colortexNFormat, shadowMapResolution and friends are parsed by name' 'DarkGray'
    foreach ($entry in ($shaderClasses | Where-Object { $_.FullName -match 'Directives|DirectiveParser|ConstDirective' })) {
        $parsed = Read-ClassFile (Read-Entry $entry)
        if ($null -eq $parsed) { continue }
        $strings = @(Get-Strings $parsed | Where-Object {
            $_ -match '(?i)format|resolution|clear|mipmap|interval|shadow|colortex|colorimg|noise|ambient|sun|wetness|drynessH|eyeBrightness|centerDepth' } | Select-Object -Unique)
        if ($strings.Count -eq 0) { continue }
        Say 'class' $parsed.Name 'Green'
        foreach ($s in ($strings | Sort-Object)) { Say '' ("  " + $s) 'Cyan' }
    }

    Head '6. texture formats'
    Show-EnumOf 'InternalTextureFormat'
    Show-EnumOf 'PixelFormat'
    Show-EnumOf 'PixelType'

    Head '7. uniforms'
    Say 'why' 'a uniform that is not uploaded silently reads as zero' 'DarkGray'
    foreach ($entry in ($shaderClasses | Where-Object { $_.FullName -match 'Uniforms\.class$' })) {
        $parsed = Read-ClassFile (Read-Entry $entry)
        if ($null -eq $parsed) { continue }
        $strings = @(Get-Strings $parsed | Where-Object { $_ -match '^[a-z][A-Za-z0-9_]{2,}$' } | Select-Object -Unique | Sort-Object)
        if ($strings.Count -eq 0) { continue }
        Say 'class' $parsed.Name 'Green'
        Say '' ("  " + ($strings -join ' ')) 'Cyan'
    }

    Head '8. standard macros'
    Say 'why' 'MC_GL_VERSION, MC_RENDER_QUALITY and any Angelica-specific defines' 'DarkGray'
    Show-StringsOf 'StandardMacros' -Filter '^(MC_|IRIS_|ANGELICA|MC_OS|MC_GL|DISTANT_HORIZONS)' -Sorted

    Head '9. compute, storage buffers, images'
    Say 'why' 'decides voxelization via SSBO+compute versus shadowcolor textures' 'DarkGray'
    foreach ($h in (Select-ByText 'glDispatchCompute|ShaderStorageBuffer|GL_SHADER_STORAGE_BUFFER|glBindImageTexture|glMemoryBarrier|GL_COMPUTE_SHADER')) {
        $parsed = Read-ClassFile $h.Bytes
        if ($null -eq $parsed) { continue }
        Say '' ("  " + $parsed.Name) 'Cyan'
    }
    foreach ($simple in @('ComputeProgram', 'ShaderStorageBuffer', 'ShaderStorageBufferHolder', 'GlImage', 'CustomImages', 'ImageHolder')) {
        $hits = Find-Class $simple
        Say ($(if ($hits.Count) { 'present' } else { 'absent' })) $simple ($(if ($hits.Count) { 'Green' } else { 'DarkYellow' }))
    }

    Head '10. version rewriting'
    Say 'why' 'whether #version 330 compatibility survives, or core is forced' 'DarkGray'
    foreach ($entry in ($shaderClasses | Where-Object { $_.FullName -match 'Transform|Patcher|Compatib|Preprocess|ShaderPrinter' })) {
        $parsed = Read-ClassFile (Read-Entry $entry)
        if ($null -eq $parsed) { continue }
        $strings = @(Get-Strings $parsed | Where-Object {
            $_ -match '#version|compatibility|\bcore\b|gl_FragData|gl_ModelViewMatrix|texture2D|ftransform|gl_FragColor|iris_|#extension|GL_ARB|alphaTestRef|irisMain' } | Select-Object -Unique)
        if ($strings.Count -eq 0) { continue }
        Say 'class' $parsed.Name 'Green'
        foreach ($s in $strings) { Say '' ("  " + ($s -replace "`n", '\n')) 'Cyan' }
    }

    Head '11. the shadow pass'
    Show-StringsOf 'PackShadowDirectives' -Filter '^[a-zA-Z]' -Sorted
    foreach ($h in (Select-ByText 'shadowcolor|shadowtex|shadowHardwareFiltering|shadowMapResolution|shadowDistance|shadowIntervalSize')) {
        $parsed = Read-ClassFile $h.Bytes
        if ($null -eq $parsed) { continue }
        Say '' ("  " + $parsed.Name) 'Cyan'
    }

    Head '12. bundled shader sources'
    Say 'why' 'internal fallbacks show the dialect the fork itself speaks' 'DarkGray'
    $sources = @($all | Where-Object { $_.FullName -match '\.(vsh|fsh|gsh|csh|glsl|properties)$' -and $_.FullName -notmatch '^META-INF' })
    Say 'count' $sources.Count 'DarkGray'
    foreach ($s in ($sources | Select-Object -First 60)) { Say '' ("  " + $s.FullName) 'Cyan' }
    $sample = $sources | Where-Object { $_.FullName -match '\.(vsh|fsh)$' } | Select-Object -First 1
    if ($sample) {
        Say 'sample' $sample.FullName 'Green'
        foreach ($line in (((Read-Text $sample) -split "`n") | Select-Object -First 25)) { Say '' ("  " + $line.TrimEnd()) 'DarkGray' }
    }

} finally {
    if ($Report) { Stop-Transcript | Out-Null }
    foreach ($z in $opened) { $z.Dispose() }
    Get-ChildItem $env:TEMP -Filter 'angelica-probe-*' -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Say 'next' '-Class FeatureFlags' 'DarkGray'
Say '' '-Class IrisRenderSystem -Method "supports|Compute|SSBO"' 'DarkGray'
Say '' '-Grep "RENDERTARGETS|DRAWBUFFERS" -Full' 'DarkGray'
Say '' '-Grep "irisMain|iris_" -Full' 'DarkGray'

