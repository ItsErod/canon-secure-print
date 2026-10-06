#!/bin/bash
# Remax Secure Printer — terminal installer for macOS.
# RE/MAX Escarpment IT. No .app, no GUI automation.
#
# Agents (admin password required):
#   curl -fsSL https://raw.githubusercontent.com/ItsErod/canon-secure-print/main/install-mac.sh | sudo bash
#
# Preset the print username (sudo does not keep exported variables):
#   curl -fsSL https://raw.githubusercontent.com/ItsErod/canon-secure-print/main/install-mac.sh \
#     | sudo REMAX_PRINT_USER='tsiogase' bash
#
# Check the Canon encode / PPD patch logic without installing:
#   bash install-mac.sh --self-test
#
# This script never edits /etc/cups/ppd in place. It stages a PPD, patches it,
# and attaches that file with lpadmin -P.

if [ -z "${BASH_VERSION:-}" ]; then
  echo "Run this installer with bash, not sh." >&2
  exit 1
fi

set -u
set -o pipefail

VERSION="1.0.0"
RAW_INSTALL_URL="https://raw.githubusercontent.com/ItsErod/canon-secure-print/main/install-mac.sh"

QUEUE="RemaxSecure"
STALE_QUEUE="RemaxSecure_COLOUR"
URI="${REMAX_PRINTER_URI:-lpd://172.16.105.21/RemaxSecure}"
PPD_GZ="/Library/Printers/PPDs/Contents/Resources/CNMCIRAC5235S2.ppd.gz"
PPD_PLAIN="/Library/Printers/PPDs/Contents/Resources/CNMCIRAC5235S2.ppd"

LOG=""
SUPPORT=""
WORKDIR=""
LOG_READY=0
REPORT_DONE=0
CANON_EMBED_FILE=""
LPADMIN=""
LPSTAT=""
PRINT_USER=""
CONSOLE_USER=""
FOUND_USER=""
FOUND_OWNER=""
DRIVER_PPD_PATH=""
STAGED_DRIVER=""

R_DRIVER="FAIL"
R_CASSETTE="FAIL"
R_FINISHER="FAIL"
R_SIDES="FAIL"
R_ENTER="FAIL"
R_QUEUE="FAIL"
R_URI="FAIL"
R_STALE="FAIL"
D_DRIVER="not checked"
D_CASSETTE="not checked"
D_FINISHER="not checked"
D_SIDES="not checked"
D_ENTER="not checked"
D_QUEUE="not checked"
D_URI="not checked"
D_STALE="not checked"

on_exit() {
  if [[ -n "${CANON_EMBED_FILE:-}" ]]; then
    rm -f "${CANON_EMBED_FILE}"
  fi
  if [[ -n "${WORKDIR:-}" ]]; then
    rm -rf "${WORKDIR}"
  fi
}
trap on_exit EXIT

say() {
  printf '[RemaxSecure] %s\n' "$*"
  if [[ -n "${LOG:-}" ]]; then
    printf '[RemaxSecure] %s\n' "$*" >> "$LOG"
  fi
}

report_line() {
  printf '%s\n' "$*"
  if [[ -n "${LOG:-}" ]]; then
    printf '%s\n' "$*" >> "$LOG"
  fi
}

embed_canon_ppd() {
  local dest="$1"
  cat > "$dest" <<'END_CANON_PPD'
#!/usr/bin/perl
# Canon PPD helper for the Remax Secure Printer installer.
#
# The Canon CUPS PS Printer Utility reads User Information only from the
# colon-form *%INFO_PrPr block in the queue PPD (not the legacy "=" block,
# and not PreferencePrintSettings.xml).
#
# Payload: UTF-8 XML -> zlib compress (default level, header 78 9c) ->
# standard base64, wrapped at 200 characters. The last line is
# END_<uncompressed byte length>. This matches Ethan Rod's 2026-10-06
# capture for print user tsiogase / console user erod exactly.
#
# After editing this file, run: python3 tests/sync-embed.py
use strict;
use warnings;
use Compress::Zlib qw(compress uncompress);
use MIME::Base64 qw(encode_base64 decode_base64);
use File::Spec;
use File::Temp qw(tempfile);

my $CHUNK = 200;

sub canon_encode {
    my ($s) = @_;
    $s = '' if !defined $s;
    utf8::encode($s) if utf8::is_utf8($s);
    my $notted = pack 'C*', map { (~$_) & 0xFF } unpack 'C*', $s;
    return encode_base64($notted, '');
}

sub canon_decode {
    my ($b64) = @_;
    return '' if !defined $b64 || $b64 eq '';
    my $raw = decode_base64($b64);
    return '' if !defined $raw;
    my $out = pack 'C*', map { (~$_) & 0xFF } unpack 'C*', $raw;
    return $out;
}

sub build_xml {
    my ($user, $owner) = @_;
    die "print username is empty\n" if !defined $user || $user eq '';
    die "console owner is empty\n"  if !defined $owner || $owner eq '';
    my $eu = canon_encode($user);
    my $eo = canon_encode($owner);
    my $ez = canon_encode('0');
    # Newline after the XML declaration and a trailing newline are part of
    # the captured byte length (END_598 for tsiogase/erod). Empty elements
    # are self-closing. Enter Name is name_set_index 1, wrapped in list_0.
    return qq{<?xml version="1.0" encoding="UTF-8"?>\n}
      . q{<CNXML><list_0>}
      . q{<user_name><string>} . $eu . q{</string></user_name>}
      . q{<secured_password><string/></secured_password>}
      . q{<box_num><string>} . $ez . q{</string></box_num>}
      . q{<display_ipfax_confirm_message><integer>1</integer></display_ipfax_confirm_message>}
      . q{<name_set_index><integer>1</integer></name_set_index>}
      . q{<job_result_notice_mode><string>None</string></job_result_notice_mode>}
      . q{<job_result_notice_contents><string>None</string></job_result_notice_contents>}
      . q{<job_result_notice_address><string/></job_result_notice_address>}
      . q{<owner><string>} . $eo . q{</string></owner>}
      . qq{</list_0></CNXML>\n};
}

sub info_lines_for {
    my ($user, $owner) = @_;
    my $xml = build_xml($user, $owner);
    my $comp = compress($xml);
    die "zlib compress failed\n" if !defined $comp;
    my $b64 = encode_base64($comp, '');
    my @lines;
    my $n = 1;
    for (my $i = 0; $i < length($b64); $i += $CHUNK) {
        push @lines, sprintf '*%%INFO_PrPr%d: %s', $n, substr($b64, $i, $CHUNK);
        $n++;
    }
    push @lines, sprintf '*%%INFO_PrPr%d: END_%d', $n, length($xml);
    return @lines;
}

sub read_ppd_lines {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "cannot read $path: $!\n";
    local $/;
    my $data = <$fh>;
    close $fh;
    $data = '' if !defined $data;
    $data =~ s/\r\n/\n/g;
    $data =~ s/\r/\n/g;
    my @lines = split /\n/, $data, -1;
    pop @lines if @lines && $lines[-1] eq '';
    return \@lines;
}

sub write_ppd_lines {
    my ($path, $lines) = @_;
    open my $fh, '>:raw', $path or die "cannot write $path: $!\n";
    print {$fh} join("\n", @$lines), "\n";
    close $fh or die "cannot close $path: $!\n";
}

sub strip_info_prpr {
    my ($lines) = @_;
    my @kept;
    for my $line (@$lines) {
        next if $line =~ /^\*%INFO_PrPr\d+\s*[:=]/;
        push @kept, $line;
    }
    return \@kept;
}

sub set_default {
    my ($lines, $key, $value) = @_;
    my $n = 0;
    for my $line (@$lines) {
        if ($line =~ /^\*\Q$key\E:/) {
            $line = "*$key: $value";
            $n++;
        }
    }
    if ($n == 0) {
        die "PPD is missing *$key (refusing to append a default outside its OpenUI group)\n";
    }
    if ($n != 1) {
        die "PPD has $n *$key lines; expected exactly one\n";
    }
}

sub apply_hardware_defaults {
    my ($lines) = @_;
    set_default($lines, 'DefaultCNSrcOption', 'OptCas2');
    set_default($lines, 'DefaultCNFinisher',  'IFINE1');
    set_default($lines, 'DefaultCNDuplex',    'None');
}

sub insert_info_after_adobe {
    my ($lines, @info) = @_;
    my @out;
    my $inserted = 0;
    for my $line (@$lines) {
        push @out, $line;
        if (!$inserted && $line =~ /^\*PPD-Adobe:/) {
            push @out, @info;
            $inserted = 1;
        }
    }
    die "PPD is missing *PPD-Adobe (cannot place INFO_PrPr near the top)\n" if !$inserted;
    return \@out;
}

sub nick_and_model {
    my ($lines) = @_;
    my ($nick, $model, $pc);
    for my $line (@$lines) {
        $nick  = $line if !defined $nick  && $line =~ /^\*NickName:/;
        $model = $line if !defined $model && $line =~ /^\*ModelName:/;
        $pc    = $line if !defined $pc    && $line =~ /^\*PCFileName:/;
    }
    return ($nick, $model, $pc);
}

# Judge the driver from NickName and ModelName only. The C5235 PPD also
# contains a "Japanese Paper" media type; that string must not reject it.
sub driver_ok {
    my ($lines) = @_;
    my ($nick, $model, $pc) = nick_and_model($lines);
    my @why;
    if (!defined $nick) {
        push @why, 'missing *NickName';
    } elsif ($nick !~ /C5235/ || $nick !~ /5240/) {
        push @why, "*NickName does not contain C5235 and 5240 ($nick)";
    }
    if (!defined $model) {
        push @why, 'missing *ModelName';
    } elsif ($model !~ /C5235/ || $model !~ /5240/) {
        push @why, "*ModelName does not contain C5235 and 5240 ($model)";
    }
    my $detail = '';
    if (!@why) {
        $detail = $nick;
        $detail .= " / $pc" if defined $pc;
    }
    return (\@why, $detail, $nick, $model, $pc);
}

our $QUIET = 0;

sub emit {
    return if $QUIET;
    my ($kind, $key, $val) = @_;
    $val = '' if !defined $val;
    $val =~ s/[\r\n]+/ /g;
    print "$kind $key $val\n";
}

sub extract_info {
    my ($lines) = @_;
    my $adobe;
    my $first_colon;
    my $equals = 0;
    my $seen_end = 0;
    my $end_len;
    my @payload;
    my $n = 0;
    for my $line (@$lines) {
        $n++;
        if (!defined $adobe && $line =~ /^\*PPD-Adobe:/) {
            $adobe = $n;
        }
        if ($line =~ /^\*%INFO_PrPr\d+\s*=/) {
            $equals++;
            next;
        }
        if ($line =~ /^\*%INFO_PrPr\d+:\s*END_(\d+)\s*$/) {
            return "more than one END_ line" if $seen_end;
            $seen_end = 1;
            $end_len = $1;
            $first_colon = $n if !defined $first_colon;
            next;
        }
        if ($line =~ /^\*%INFO_PrPr\d+:\s*(\S+)\s*$/) {
            return "INFO_PrPr payload appears after END_" if $seen_end;
            $first_colon = $n if !defined $first_colon;
            push @payload, $1;
        }
    }
    return "legacy *%INFO_PrPr= block is present; the utility does not read it and it must be removed"
      if $equals;
    return "no colon-form *%INFO_PrPr block" if !@payload || !$seen_end;
    return "*PPD-Adobe line is missing" if !defined $adobe;
    if ($first_colon <= $adobe) {
        return "*%INFO_PrPr appears before *PPD-Adobe";
    }
    if (($first_colon - $adobe) > 15) {
        return "*%INFO_PrPr is not near the top (more than 15 lines after *PPD-Adobe)";
    }
    my $b64 = join '', @payload;
    my $raw = decode_base64($b64);
    return "INFO_PrPr base64 did not decode" if !defined $raw || $raw eq '';
    my $xml = uncompress($raw);
    return "INFO_PrPr zlib decompress failed" if !defined $xml;
    if (length($xml) != $end_len) {
        return sprintf 'END_%d does not match uncompressed XML length %d', $end_len, length($xml);
    }
    return (undef, $xml, $end_len, $first_colon, $adobe);
}

sub xml_field {
    my ($xml, $tag) = @_;
    if ($xml =~ m{<\Q$tag\E><string>([^<]*)</string></\Q$tag\E>}) {
        return $1;
    }
    return undef;
}

sub verify_ppd {
    my ($path, $expect_user, $expect_owner) = @_;
    my $any_fail = 0;
    my $lines;
    if (!-f $path) {
        emit('result', 'DRIVER', 'FAIL');
        emit('detail', 'DRIVER', "PPD not found: $path");
        for my $k (qw(CASSETTE FINISHER SIDES ENTER_NAME)) {
            emit('result', $k, 'FAIL');
            emit('detail', $k, 'PPD not found');
        }
        return 1;
    }
    eval { $lines = read_ppd_lines($path); 1 } or do {
        my $err = $@ || 'read failed';
        $err =~ s/\s+\z//;
        emit('result', 'DRIVER', 'FAIL');
        emit('detail', 'DRIVER', $err);
        for my $k (qw(CASSETTE FINISHER SIDES ENTER_NAME)) {
            emit('result', $k, 'FAIL');
            emit('detail', $k, $err);
        }
        return 1;
    };

    my ($why, $detail) = driver_ok($lines);
    if (@$why) {
        $any_fail = 1;
        emit('result', 'DRIVER', 'FAIL');
        emit('detail', 'DRIVER', join('; ', @$why));
    } else {
        emit('result', 'DRIVER', 'PASS');
        emit('detail', 'DRIVER', $detail);
    }

    my %want = (
        CASSETTE => ['DefaultCNSrcOption', 'OptCas2', 'Cassette Feeding Unit ON'],
        FINISHER => ['DefaultCNFinisher',  'IFINE1',  'Inner Finisher E1'],
        SIDES    => ['DefaultCNDuplex',    'None',    '1-sided Printing'],
    );
    for my $key (qw(CASSETTE FINISHER SIDES)) {
        my ($kw, $val, $human) = @{$want{$key}};
        my $found;
        for my $line (@$lines) {
            if ($line =~ /^\*\Q$kw\E:\s*(\S+)\s*$/) {
                $found = $1;
                last;
            }
        }
        if (defined $found && $found eq $val) {
            emit('result', $key, 'PASS');
            emit('detail', $key, "*$kw: $val ($human)");
        } else {
            $any_fail = 1;
            my $got = defined $found ? $found : 'missing';
            emit('result', $key, 'FAIL');
            emit('detail', $key, "*$kw expected $val ($human), found $got");
        }
    }

    my ($info_err, $xml) = extract_info($lines);
    if ($info_err) {
        $any_fail = 1;
        emit('result', 'ENTER_NAME', 'FAIL');
        emit('detail', 'ENTER_NAME', $info_err);
        return $any_fail ? 1 : 0;
    }

    my @shape_err;
    if ($xml !~ /\A<\?xml version="1\.0" encoding="UTF-8"\?>\n<CNXML><list_0>/) {
        push @shape_err, 'XML declaration or list_0 wrapper does not match';
    }
    if ($xml !~ m{<name_set_index><integer>1</integer></name_set_index>}) {
        push @shape_err, 'name_set_index is not 1 (Enter Name)';
    }
    if ($xml =~ m{<name_set_index><integer>2</integer></name_set_index>}) {
        push @shape_err, 'name_set_index 2 is Log-in name, not Enter Name';
    }
    if ($xml !~ m{<secured_password><string/></secured_password>}) {
        push @shape_err, 'secured_password is not an empty self-closing string';
    }
    if ($xml !~ m{<box_num><string>zw==</string></box_num>}) {
        push @shape_err, 'box_num is not zw== (Canon-encoded 0)';
    }
    if ($xml !~ m{<display_ipfax_confirm_message><integer>1</integer></display_ipfax_confirm_message>}) {
        push @shape_err, 'display_ipfax_confirm_message is not 1';
    }
    if ($xml !~ m{<job_result_notice_mode><string>None</string></job_result_notice_mode>}) {
        push @shape_err, 'job_result_notice_mode is not None';
    }
    if ($xml !~ m{<job_result_notice_contents><string>None</string></job_result_notice_contents>}) {
        push @shape_err, 'job_result_notice_contents is not None';
    }
    if ($xml !~ m{<job_result_notice_address><string/></job_result_notice_address>}) {
        push @shape_err, 'job_result_notice_address is not empty';
    }
    if ($xml !~ m{</list_0></CNXML>\n\z}) {
        push @shape_err, 'XML does not end with </list_0></CNXML> and a newline';
    }

    my $user_b64  = xml_field($xml, 'user_name');
    my $owner_b64 = xml_field($xml, 'owner');
    my $user      = defined $user_b64  ? canon_decode($user_b64)  : '';
    my $owner     = defined $owner_b64 ? canon_decode($owner_b64) : '';
    emit('field', 'user', $user);
    emit('field', 'owner', $owner);
    emit('field', 'name_set_index', '1');

    if (!defined $user_b64 || $user eq '') {
        push @shape_err, 'user_name did not decode';
    }
    if (!defined $owner_b64 || $owner eq '') {
        push @shape_err, 'owner did not decode';
    }
    if (defined $expect_user && $expect_user ne '' && $user ne $expect_user) {
        push @shape_err, "user_name decodes to '$user', expected '$expect_user'";
    }
    if (defined $expect_owner && $expect_owner ne '' && $owner ne $expect_owner) {
        push @shape_err, "owner decodes to '$owner', expected '$expect_owner'";
    }
    if (defined $user_b64 && canon_encode($user) ne $user_b64) {
        push @shape_err, 'user_name is not Canon bitwise-NOT base64';
    }
    if (defined $owner_b64 && canon_encode($owner) ne $owner_b64) {
        push @shape_err, 'owner is not Canon bitwise-NOT base64';
    }

    if (@shape_err) {
        $any_fail = 1;
        emit('result', 'ENTER_NAME', 'FAIL');
        emit('detail', 'ENTER_NAME', join('; ', @shape_err));
    } else {
        emit('result', 'ENTER_NAME', 'PASS');
        emit('detail', 'ENTER_NAME',
            "PPD Canon-format INFO_PrPr name_set_index 1 user $user owner $owner");
    }
    return $any_fail ? 1 : 0;
}

sub cmd_validate_driver {
    my ($path) = @_;
    die "usage: validate-driver PPD\n" if !defined $path;
    my $lines = read_ppd_lines($path);
    my ($why, $detail) = driver_ok($lines);
    if (@$why) {
        die join('; ', @$why) . "\n";
    }
    print "$detail\n";
    return 0;
}

sub cmd_patch_hardware {
    my ($in, $out) = @_;
    die "usage: patch-hardware IN OUT\n" if !defined $in || !defined $out;
    my $lines = read_ppd_lines($in);
    my ($why) = driver_ok($lines);
    die join('; ', @$why) . "\n" if @$why;
    apply_hardware_defaults($lines);
    write_ppd_lines($out, $lines);
    return 0;
}

sub cmd_patch_info {
    my ($in, $out, $user, $owner) = @_;
    die "usage: patch-info IN OUT USER OWNER\n"
      if !defined $in || !defined $out || !defined $user || !defined $owner;
    my $lines = strip_info_prpr(read_ppd_lines($in));
    my ($why) = driver_ok($lines);
    die join('; ', @$why) . "\n" if @$why;
    apply_hardware_defaults($lines);
    my @info = info_lines_for($user, $owner);
    $lines = insert_info_after_adobe($lines, @info);
    write_ppd_lines($out, $lines);
    return 0;
}

sub cmd_encode {
    my ($text) = @_;
    die "usage: encode TEXT\n" if !defined $text;
    print canon_encode($text), "\n";
    return 0;
}

sub cmd_decode {
    my ($text) = @_;
    die "usage: decode B64\n" if !defined $text;
    print canon_decode($text), "\n";
    return 0;
}

sub gold_lines {
    return (
        '*%INFO_PrPr1: eJyNksFOwzAMhu97iql3yIY4cEizAxKHCSYhgeBmdY1XZTR2Fae04+npRLsVpgG3yP78+7djvWh9OX3HII4pTeaXs2SKlLN1VKTJ89PdxU2yMBN9u3p9uDe6dBJhZnQtGIAyj0ZLDB1r3PXu5W3pcLvkVKs+qNUYxLwOaKHKRBoOdihVHXaaW3MLVPuD/keTjnUPaeuk',
        '*%INFO_PrPr2: KrMduGqTtZAzbVzw4FEkK7qmjiIWGMxcq+Gp1R81e7sgGMGRxfaMxk9oy2sIKHUZgTi6HMGzPa5nxYQj++fo03jnLiJF+b/SseI0l1nbBWS8+l8gbmg/a9/L89Wj//4LPaCGs1BfZzL5BGmx34A=',
        '*%INFO_PrPr3: END_598',
    );
}

sub write_temp_ppd {
    my (@body) = @_;
    my ($fh, $path) = tempfile(
        'remax-ppd-XXXX',
        DIR    => File::Spec->tmpdir,
        SUFFIX => '.ppd',
        UNLINK => 0,
    );
    print {$fh} join("\n", @body), "\n";
    close $fh;
    return $path;
}

sub self_test {
    my $fail = 0;
    my $checks = 0;
    my $ok = sub {
        my ($cond, $msg) = @_;
        $checks++;
        if (!$cond) {
            $fail++;
            print "FAIL $msg\n";
        }
    };

    $ok->(canon_encode('tsiogase') eq 'i4yWkJiejJo=', 'encode tsiogase');
    $ok->(canon_encode('erod') eq 'mo2Qmw==', 'encode erod');
    $ok->(canon_encode('0') eq 'zw==', 'encode 0');
    $ok->(canon_decode('i4yWkJiejJo=') eq 'tsiogase', 'decode tsiogase');
    $ok->(canon_decode('mo2Qmw==') eq 'erod', 'decode erod');
    $ok->(canon_decode(canon_encode("caf\x{e9}")) eq "caf\x{e9}", 'utf-8 roundtrip');

    my @got = info_lines_for('tsiogase', 'erod');
    my @gold = gold_lines();
    $ok->(join("\n", @got) eq join("\n", @gold), 'INFO_PrPr matches 2026-10-06 capture');
    $ok->(length($got[0]) > 14 && (length($got[0]) - length('*%INFO_PrPr1: ')) == 200,
        'first payload chunk is 200 chars');

    my @base = (
        '*PPD-Adobe: "4.3"',
        '*%INFO_PrPr1: b2xkY29sb24=',
        '*%INFO_PrPr2: END_3',
        '*PCFileName: "CNMCIRAC5235S2.PPD"',
        '*ModelName: "Canon iR-ADV C5235/5240 P"',
        '*NickName: "Canon iR-ADV C5235/5240 PS"',
        '*OpenUI *CNSrcOption/Cassette Feeding Unit: PickOne',
        '*DefaultCNSrcOption: None',
        '*CNSrcOption OptCas2/On: ""',
        '*CloseUI: *CNSrcOption',
        '*OpenUI *CNFinisher/Output Options: PickOne',
        '*DefaultCNFinisher: None',
        '*CNFinisher IFINE1/Inner Finisher E1: ""',
        '*CloseUI: *CNFinisher',
        '*OpenUI *CNDuplex/Print Style: PickOne',
        '*DefaultCNDuplex: DuplexFront',
        '*CNDuplex None/1-sided Printing: ""',
        '*CloseUI: *CNDuplex',
        '*CNInSlotManMediaType JAPANESE/Japanese Paper: ""',
        '*%INFO_PrPr1=PD94bWwgdmVyc2lvbj0iMS4wIiBlbmNvZGluZz0iVVRGLTgiPz4=',
        '*%INFO_PrPr2=END_38',
    );
    my $src = write_temp_ppd(@base);

    my ($why) = driver_ok(read_ppd_lines($src));
    $ok->(!@$why, 'Japanese Paper does not reject a real C5235/5240 NickName');

    my @bad = (
        '*PPD-Adobe: "4.3"',
        '*ModelName: "Japanese Paper Tray"',
        '*NickName: "Japanese Paper"',
        '*DefaultCNSrcOption: OptCas2',
        '*DefaultCNFinisher: IFINE1',
        '*DefaultCNDuplex: None',
    );
    my $bad_path = write_temp_ppd(@bad);
    my ($bad_why) = driver_ok(read_ppd_lines($bad_path));
    $ok->(scalar(@$bad_why) >= 1, 'Japanese Paper alone is not a C5235 driver');

    my $hw = "$src.hw.ppd";
    my $final = "$src.final.ppd";
    eval { cmd_patch_hardware($src, $hw); 1 } or do {
        $ok->(0, "patch-hardware: $@");
    };
    eval { cmd_patch_info($hw, $final, 'tsiogase', 'erod'); 1 } or do {
        $ok->(0, "patch-info: $@");
    };

    my $out_lines = read_ppd_lines($final);
    my $text = join("\n", @$out_lines);
    $ok->($text !~ /^\*%INFO_PrPr\d+\s*=/m, 'legacy = INFO_PrPr removed');
    $ok->($text =~ /^\*DefaultCNSrcOption: OptCas2$/m, 'cassette default patched');
    $ok->($text =~ /^\*DefaultCNFinisher: IFINE1$/m, 'finisher default patched');
    $ok->($text =~ /^\*DefaultCNDuplex: None$/m, 'one-sided default patched');
    $ok->($text =~ /Japanese Paper/, 'Japanese Paper line preserved');
    my $joined_info = join("\n", @gold);
    $ok->(index($text, $joined_info) >= 0, 'patched PPD contains gold INFO_PrPr');
    $ok->($out_lines->[0] eq '*PPD-Adobe: "4.3"', 'PPD-Adobe stays first');
    $ok->($out_lines->[1] eq $gold[0], 'INFO_PrPr starts on the next line');

    my $rc;
    {
        local $QUIET = 1;
        $rc = verify_ppd($final, 'tsiogase', 'erod');
    }
    $ok->($rc == 0, 'verify gold PPD passes');
    if ($rc != 0) {
        verify_ppd($final, 'tsiogase', 'erod');
    }

    my $legacy = write_temp_ppd(
        '*PPD-Adobe: "4.3"',
        '*ModelName: "Canon iR-ADV C5235/5240 P"',
        '*NickName: "Canon iR-ADV C5235/5240 PS"',
        '*DefaultCNSrcOption: OptCas2',
        '*DefaultCNFinisher: IFINE1',
        '*DefaultCNDuplex: None',
        '*%INFO_PrPr1=PD94bWw=',
        '*%INFO_PrPr2=END_5',
    );
    my $legacy_rc;
    {
        local $QUIET = 1;
        $legacy_rc = verify_ppd($legacy, 'tsiogase', 'erod');
    }
    $ok->($legacy_rc != 0, 'equals-only INFO_PrPr fails Enter Name');
    if ($legacy_rc == 0) {
        verify_ppd($legacy, 'tsiogase', 'erod');
    }

    unlink $src, $hw, $final, $bad_path, $legacy;

    if ($fail) {
        print "SELF-TEST FAIL ($fail of $checks)\n";
        return 1;
    }
    print "SELF-TEST PASS ($checks checks)\n";
    return 0;
}

sub usage {
    die <<"END";
usage: canon_ppd.pl COMMAND ...
  self-test
  encode TEXT
  decode B64
  validate-driver PPD
  patch-hardware IN OUT
  patch-info IN OUT USER OWNER
  verify PPD [USER] [OWNER]
END
}

my $cmd = shift @ARGV;
usage() if !defined $cmd;
my $rc;
if ($cmd eq 'self-test') {
    $rc = self_test();
} elsif ($cmd eq 'encode') {
    $rc = cmd_encode($ARGV[0]);
} elsif ($cmd eq 'decode') {
    $rc = cmd_decode($ARGV[0]);
} elsif ($cmd eq 'validate-driver') {
    $rc = cmd_validate_driver($ARGV[0]);
} elsif ($cmd eq 'patch-hardware') {
    $rc = cmd_patch_hardware($ARGV[0], $ARGV[1]);
} elsif ($cmd eq 'patch-info') {
    $rc = cmd_patch_info($ARGV[0], $ARGV[1], $ARGV[2], $ARGV[3]);
} elsif ($cmd eq 'verify') {
    $rc = verify_ppd($ARGV[0], $ARGV[1], $ARGV[2]);
} else {
    usage();
}
exit($rc || 0);
END_CANON_PPD
}

canon_ppd() {
  local src lib
  src="${BASH_SOURCE[0]}"
  if [[ -n "$src" && "$src" != "bash" && "$src" != "main" && "$src" != "-" && -f "$src" ]]; then
    lib="$(cd "$(dirname "$src")" && pwd)/lib/canon_ppd.pl"
    if [[ -f "$lib" ]]; then
      perl "$lib" "$@"
      return
    fi
  fi
  if [[ -z "${CANON_EMBED_FILE}" || ! -f "${CANON_EMBED_FILE}" ]]; then
    CANON_EMBED_FILE="$(mktemp "${TMPDIR:-/tmp}/remax-canon.XXXXXX")"
    embed_canon_ppd "$CANON_EMBED_FILE"
  fi
  perl "$CANON_EMBED_FILE" "$@"
}

usage() {
  cat <<EOF
Remax Secure Printer installer ${VERSION} (macOS, terminal only)

  curl -fsSL ${RAW_INSTALL_URL} | sudo bash

  curl -fsSL ${RAW_INSTALL_URL} | sudo REMAX_PRINT_USER='tsiogase' bash

  sudo REMAX_PRINT_USER='tsiogase' bash install-mac.sh
  bash install-mac.sh --self-test
  bash install-mac.sh --help

Environment:
  REMAX_PRINT_USER       Print username (Enter Name). Prompted from /dev/tty if unset.
  REMAX_CONSOLE_USER     Override the console Mac user stored as owner.
  REMAX_CANON_PKG_URL    Optional http(s) URL of a Canon .pkg, .dmg, or .zip to
                         install when CNMCIRAC5235S2 is not already on the Mac.
  REMAX_PRINTER_URI      Default: lpd://172.16.105.21/RemaxSecure

The Canon CUPS PS Printer Utility reads Enter Name from the colon-form
*%INFO_PrPr block written into the RemaxSecure PPD. No GUI automation.
EOF
}

require_perl() {
  if ! command -v perl >/dev/null 2>&1; then
    echo "perl is required. It ships with macOS; this Mac does not have it on PATH." >&2
    exit 1
  fi
  if ! perl -MCompress::Zlib -e '1' >/dev/null 2>&1; then
    echo "Perl Compress::Zlib is required. It ships with macOS." >&2
    exit 1
  fi
}

init_log() {
  if [[ "${REMAX_TEST_MODE:-}" == "1" ]]; then
    WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/remax-secure.XXXXXX")"
    LOG="${REMAX_LOG:-$WORKDIR/RemaxSecurePrinterSetup-mac.log}"
    SUPPORT="${REMAX_SUPPORT_DIR:-$WORKDIR/support}"
  else
    WORKDIR="$(mktemp -d /tmp/remax-secure.XXXXXX)"
    LOG="/tmp/RemaxSecurePrinterSetup-mac.log"
    SUPPORT="/Library/Application Support/RemaxSecurePrinter"
  fi
  mkdir -p "$SUPPORT"
  {
    echo "Remax Secure Printer installer ${VERSION}"
    echo "date: $(date)"
    echo "uname: $(uname -a 2>/dev/null || uname)"
  } > "$LOG"
  LOG_READY=1
}

check_platform() {
  if [[ "$(uname -s)" != "Darwin" && "${REMAX_TEST_MODE:-}" != "1" ]]; then
    echo "This installer is for macOS. Detected $(uname -s)." >&2
    exit 1
  fi
}

check_root() {
  if [[ "${REMAX_TEST_MODE:-}" == "1" ]]; then
    return 0
  fi
  if [[ "$(id -u)" -ne 0 ]]; then
    cat <<EOF
This installer must run as an administrator.

  curl -fsSL ${RAW_INSTALL_URL} | sudo bash

To set the print username without a prompt (put the variable on sudo; sudo
drops ordinary exported variables):

  curl -fsSL ${RAW_INSTALL_URL} | sudo REMAX_PRINT_USER='tsiogase' bash
EOF
    exit 1
  fi
}

resolve_tools() {
  if [[ -n "${REMAX_LPADMIN:-}" ]]; then
    LPADMIN="${REMAX_LPADMIN}"
  elif [[ -x /usr/sbin/lpadmin ]]; then
    LPADMIN="/usr/sbin/lpadmin"
  elif command -v lpadmin >/dev/null 2>&1; then
    LPADMIN="$(command -v lpadmin)"
  else
    echo "lpadmin was not found. CUPS client tools are required." >&2
    exit 1
  fi
  if [[ -n "${REMAX_LPSTAT:-}" ]]; then
    LPSTAT="${REMAX_LPSTAT}"
  elif command -v lpstat >/dev/null 2>&1; then
    LPSTAT="$(command -v lpstat)"
  else
    echo "lpstat was not found. CUPS client tools are required." >&2
    exit 1
  fi
  if [[ ! -x "$LPADMIN" && ! -f "$LPADMIN" ]]; then
    echo "lpadmin is not executable: $LPADMIN" >&2
    exit 1
  fi
}

valid_account_name() {
  local name="$1"
  [[ "$name" =~ ^[A-Za-z0-9._-]{1,64}$ ]]
}

trim_spaces() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

prompt_print_user() {
  local u="" arg="${1:-}"
  if [[ -n "${REMAX_PRINT_USER:-}" ]]; then
    u="${REMAX_PRINT_USER}"
  elif [[ -n "$arg" ]]; then
    u="$arg"
  else
    if ! { exec 3</dev/tty; } 2>/dev/null; then
      cat <<EOF
No terminal is available to ask for the print username, and REMAX_PRINT_USER is unset.

  curl -fsSL ${RAW_INSTALL_URL} | sudo REMAX_PRINT_USER='tsiogase' bash
EOF
      exit 1
    fi
    if ! [[ -t 3 ]]; then
      exec 3<&-
      echo "REMAX_PRINT_USER is unset and /dev/tty is not a terminal." >&2
      exit 1
    fi
    printf 'Print username (Enter Name, the name on the copier): ' >&3
    IFS= read -r u <&3 || true
    exec 3<&-
    u="$(trim_spaces "$u")"
  fi
  u="$(trim_spaces "$u")"
  if ! valid_account_name "$u"; then
    echo "Print username must be 1-64 characters: letters, digits, dot, underscore, hyphen." >&2
    exit 1
  fi
  PRINT_USER="$u"
}

detect_console_user() {
  local u="" s=""
  if [[ -n "${REMAX_CONSOLE_USER:-}" ]]; then
    u="${REMAX_CONSOLE_USER}"
  else
    if command -v scutil >/dev/null 2>&1; then
      u="$(scutil <<< "show State:/Users/ConsoleUser" 2>/dev/null | awk '/Name :/ { print $3; exit }')"
    fi
    if [[ -z "$u" || "$u" == "loginwindow" || "$u" == "root" ]]; then
      s="$(stat -f '%Su' /dev/console 2>/dev/null || true)"
      if [[ -n "$s" && "$s" != "root" && "$s" != "loginwindow" ]]; then
        u="$s"
      fi
    fi
    if [[ -z "$u" || "$u" == "loginwindow" || "$u" == "root" ]]; then
      if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        u="${SUDO_USER}"
      fi
    fi
  fi
  if ! valid_account_name "${u:-}"; then
    cat <<EOF
Could not detect the console Mac user, which is stored as the Canon owner.

Log in on the Mac desktop and run the installer again, or set it explicitly:

  sudo REMAX_PRINT_USER='tsiogase' REMAX_CONSOLE_USER='shortname' bash install-mac.sh
EOF
    exit 1
  fi
  CONSOLE_USER="$u"
}

log_preference_paths() {
  local home=""
  if command -v dscl >/dev/null 2>&1; then
    home="$(dscl . -read "/Users/${CONSOLE_USER}" NFSHomeDirectory 2>/dev/null | awk '{ print $2; exit }')"
  fi
  if [[ -z "$home" ]]; then
    home="/Users/${CONSOLE_USER}"
  fi
  say "Console home: ${home}"
  say "Owner in INFO_PrPr will be ${CONSOLE_USER} (not root, not the print username unless they match)."
  say "Not modified: ${home}/Library/Containers/jp.co.canon.CUPS.PS2.PrinterUtility"
  say "Not modified: ${home}/Library/Application Support/Canon/CUPSPS2"
  say "Enter Name is written only as colon-form *%INFO_PrPr in the queue PPD."
}

installed_ppd_path() {
  printf '%s/%s.ppd' "${REMAX_CUPS_PPD_DIR:-/etc/cups/ppd}" "$QUEUE"
}

queue_exists() {
  "$LPSTAT" -p "$1" >/dev/null 2>&1
}

device_uri() {
  local line
  line="$("$LPSTAT" -v "$QUEUE" 2>>"$LOG" || true)"
  printf '%s\n' "$line" | sed -n 's/^device for [^:]*:[[:space:]]*//p' | head -n 1 | tr -d '\r'
}

run_cmd() {
  say "run: $*"
  if "$@" >>"$LOG" 2>&1; then
    return 0
  fi
  local rc=$?
  say "command failed (${rc}): $*"
  return "$rc"
}

print_driver_help() {
  cat <<EOF
The Canon PS driver for iR-ADV C5235/5240 is not installed on this Mac.
This installer does not ship the Canon driver.

Expected file (either one):
  ${PPD_GZ}
  ${PPD_PLAIN}

On the RE/MAX Escarpment fleet this package is usually already installed.
Install "Canon iR-ADV C5235/5240 PS" (CUPS PS, model CNMCIRAC5235S2), then
run this installer again.

To have this script install a package you host, set REMAX_CANON_PKG_URL to
an http(s) URL ending in .pkg, .dmg, or .zip:

  curl -fsSL ${RAW_INSTALL_URL} | sudo \\
    REMAX_CANON_PKG_URL='https://example.invalid/CanonPS.pkg' \\
    REMAX_PRINT_USER='${PRINT_USER}' bash
EOF
}

find_driver_ppd() {
  local found=""
  DRIVER_PPD_PATH=""
  if [[ -n "${REMAX_PPD_SOURCE:-}" ]]; then
    if [[ ! -f "${REMAX_PPD_SOURCE}" ]]; then
      echo "REMAX_PPD_SOURCE does not exist: ${REMAX_PPD_SOURCE}" >&2
      exit 1
    fi
    DRIVER_PPD_PATH="${REMAX_PPD_SOURCE}"
    return 0
  fi
  if [[ -f "$PPD_GZ" ]]; then
    DRIVER_PPD_PATH="$PPD_GZ"
    return 0
  fi
  if [[ -f "$PPD_PLAIN" ]]; then
    DRIVER_PPD_PATH="$PPD_PLAIN"
    return 0
  fi
  if [[ -d /Library/Printers ]]; then
    found="$(find /Library/Printers \( -name 'CNMCIRAC5235S2.ppd.gz' -o -name 'CNMCIRAC5235S2.ppd' \) 2>/dev/null | head -n 1 || true)"
  fi
  if [[ -n "$found" && -f "$found" ]]; then
    DRIVER_PPD_PATH="$found"
    return 0
  fi
  return 1
}

stage_driver() {
  STAGED_DRIVER="${WORKDIR}/driver.ppd"
  case "$DRIVER_PPD_PATH" in
    *.gz|*.GZ)
      say "Decompressing ${DRIVER_PPD_PATH}"
      gzip -dc "$DRIVER_PPD_PATH" > "$STAGED_DRIVER"
      ;;
    *)
      say "Staging ${DRIVER_PPD_PATH}"
      cp "$DRIVER_PPD_PATH" "$STAGED_DRIVER"
      ;;
  esac
}

install_flat_pkg() {
  local pkg="$1"
  if ! command -v installer >/dev/null 2>&1; then
    say "installer(8) is not available on this Mac."
    return 1
  fi
  run_cmd installer -pkg "$pkg" -target /
}

install_from_dmg() {
  local dmg="$1"
  local mount="${WORKDIR}/dmg-mount"
  local pkg=""
  mkdir -p "$mount"
  if ! command -v hdiutil >/dev/null 2>&1; then
    say "hdiutil is not available; cannot open the driver disk image."
    return 1
  fi
  say "Mounting Canon driver disk image"
  if ! hdiutil attach -nobrowse -mountpoint "$mount" "$dmg" >>"$LOG" 2>&1; then
    say "Could not mount the driver disk image. See ${LOG}"
    return 1
  fi
  pkg="$(find "$mount" -name '*.pkg' -print 2>/dev/null | head -n 1 || true)"
  if [[ -z "$pkg" ]]; then
    hdiutil detach "$mount" >>"$LOG" 2>&1 || true
    say "The disk image does not contain a .pkg."
    return 1
  fi
  install_flat_pkg "$pkg"
  local rc=$?
  hdiutil detach "$mount" >>"$LOG" 2>&1 || true
  return "$rc"
}

install_from_zip() {
  local zip="$1"
  local dest="${WORKDIR}/pkg-unzip"
  local pkg=""
  mkdir -p "$dest"
  if ! command -v unzip >/dev/null 2>&1; then
    say "unzip is not available."
    return 1
  fi
  if ! unzip -q "$zip" -d "$dest" >>"$LOG" 2>&1; then
    say "Could not unzip the driver package."
    return 1
  fi
  pkg="$(find "$dest" -name '*.pkg' -print 2>/dev/null | head -n 1 || true)"
  if [[ -z "$pkg" ]]; then
    say "The zip does not contain a .pkg."
    return 1
  fi
  install_flat_pkg "$pkg"
}

install_driver_url() {
  local url="$1"
  local dest="${WORKDIR}/canon-driver.download"
  local lower
  say "Downloading Canon driver package"
  if ! command -v curl >/dev/null 2>&1; then
    say "curl is not available."
    return 1
  fi
  if ! curl -fL --retry 3 --retry-delay 2 -o "$dest" "$url" >>"$LOG" 2>&1; then
    say "Download failed. See ${LOG}"
    return 1
  fi
  lower="$(printf '%s' "$url" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    *.dmg) install_from_dmg "$dest" ;;
    *.zip) install_from_zip "$dest" ;;
    *) install_flat_pkg "$dest" ;;
  esac
}

ppd_has_defaults() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  grep -q '^\*DefaultCNSrcOption: OptCas2$' "$f" \
    && grep -q '^\*DefaultCNFinisher: IFINE1$' "$f" \
    && grep -q '^\*DefaultCNDuplex: None$' "$f"
}

# Attach a staged PPD. Do not open the live queue PPD for writing.
attach_ppd() {
  local ppd="$1"
  run_cmd "$LPADMIN" -p "$QUEUE" -v "$URI" -P "$ppd" \
    -D "RE/MAX Secure Printer" -L "RE/MAX Escarpment" -E
}

apply_options() {
  run_cmd "$LPADMIN" -p "$QUEUE" \
    -o CNSrcOption=OptCas2 \
    -o CNFinisher=IFINE1 \
    -o CNDuplex=None
}

parse_canon_output() {
  local file="$1" line kind rest key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    printf '    %s\n' "$line" >> "$LOG"
    kind="${line%% *}"
    rest="${line#* }"
    key="${rest%% *}"
    if [[ "$rest" == "$key" ]]; then
      val=""
    else
      val="${rest#* }"
    fi
    case "${kind}:${key}" in
      result:DRIVER) R_DRIVER="$val" ;;
      result:CASSETTE) R_CASSETTE="$val" ;;
      result:FINISHER) R_FINISHER="$val" ;;
      result:SIDES) R_SIDES="$val" ;;
      result:ENTER_NAME) R_ENTER="$val" ;;
      detail:DRIVER) D_DRIVER="$val" ;;
      detail:CASSETTE) D_CASSETTE="$val" ;;
      detail:FINISHER) D_FINISHER="$val" ;;
      detail:SIDES) D_SIDES="$val" ;;
      detail:ENTER_NAME) D_ENTER="$val" ;;
      field:user) FOUND_USER="$val" ;;
      field:owner) FOUND_OWNER="$val" ;;
    esac
  done < "$file"
}

refresh_queue_checks() {
  local got="" installed
  installed="$(installed_ppd_path)"
  if queue_exists "$QUEUE" && [[ -f "$installed" ]]; then
    R_QUEUE="PASS"
    D_QUEUE="${QUEUE} is installed (${installed})"
  else
    R_QUEUE="FAIL"
    D_QUEUE="${QUEUE} is not installed"
  fi
  got="$(device_uri || true)"
  if [[ "$got" == "$URI" ]]; then
    R_URI="PASS"
    D_URI="$got"
  else
    R_URI="FAIL"
    D_URI="expected ${URI}, lpstat returned '${got:-nothing}'"
  fi
  if queue_exists "$STALE_QUEUE"; then
    R_STALE="FAIL"
    D_STALE="${STALE_QUEUE} is still installed"
  else
    R_STALE="PASS"
    D_STALE="absent"
  fi
}

overall_pass() {
  local k
  for k in "$R_DRIVER" "$R_CASSETTE" "$R_FINISHER" "$R_SIDES" "$R_ENTER" "$R_QUEUE" "$R_URI" "$R_STALE"; do
    [[ "$k" == "PASS" ]] || return 1
  done
  return 0
}

print_report() {
  local result="FAIL"
  if overall_pass; then
    result="PASS"
  fi
  report_line "======== Remax Secure Printer INSTALL REPORT ========"
  report_line "RESULT:      ${result}"
  report_line "QUEUE:       ${R_QUEUE}  ${D_QUEUE}"
  report_line "URI:         ${R_URI}  ${D_URI}"
  report_line "DRIVER:      ${R_DRIVER}  ${D_DRIVER}"
  report_line "CASSETTE:    ${R_CASSETTE}  ${D_CASSETTE}"
  report_line "FINISHER:    ${R_FINISHER}  ${D_FINISHER}"
  report_line "SIDES:       ${R_SIDES}  ${D_SIDES}"
  report_line "ENTER NAME:  ${R_ENTER}  ${D_ENTER}"
  report_line "STALE QUEUE: ${R_STALE}  ${D_STALE}"
  report_line "Print user:  ${PRINT_USER:-unknown}"
  report_line "Owner:       ${CONSOLE_USER:-unknown}"
  if [[ -n "$FOUND_USER" || -n "$FOUND_OWNER" ]]; then
    report_line "Decoded:     user ${FOUND_USER:-?}  owner ${FOUND_OWNER:-?}"
  fi
  report_line "Log:         ${LOG}"
  report_line "Copy:        ${SUPPORT}/"
  report_line "======================================================"
  if [[ "$result" == "PASS" ]]; then
    report_line "Open Canon CUPS PS Printer Utility, select ${QUEUE}, then User Information."
    report_line "Enter Name should show ${PRINT_USER}. Quit and reopen the utility if it was already running."
    report_line "Nothing in this installer clicks the Utility. It only writes the PPD."
  else
    report_line "Install is incomplete. Fix the FAIL lines above and run the installer again."
    report_line "Full log: ${LOG}"
  fi
}

copy_log() {
  local stamp result_word="FAIL"
  if overall_pass; then
    result_word="PASS"
  fi
  if ! mkdir -p "$SUPPORT" 2>>"$LOG"; then
    say "Could not create ${SUPPORT}"
    return 0
  fi
  cp -f "$LOG" "${SUPPORT}/RemaxSecurePrinterSetup-mac.log" 2>>"$LOG" || true
  stamp="$(date +%Y%m%d-%H%M%S)"
  cp -f "$LOG" "${SUPPORT}/RemaxSecurePrinterSetup-mac-${stamp}.log" 2>>"$LOG" || true
  cat > "${SUPPORT}/last-install.txt" <<EOF
date=$(date)
version=${VERSION}
result=${result_word}
print_user=${PRINT_USER}
console_user=${CONSOLE_USER}
queue=${QUEUE}
uri=${URI}
ppd=$(installed_ppd_path)
EOF
}

finalize_report() {
  local rc="$1"
  refresh_queue_checks || true
  print_report
  copy_log || true
  REPORT_DONE=1
  exit "$rc"
}

run_ppd_verify() {
  local installed out rc=0
  installed="$(installed_ppd_path)"
  out="${WORKDIR}/verify.out"
  say "Verifying installed PPD ${installed}"
  canon_ppd verify "$installed" "$PRINT_USER" "$CONSOLE_USER" >"$out" 2>>"$LOG" || rc=$?
  parse_canon_output "$out"
  return "$rc"
}

remove_stale_queue() {
  if queue_exists "$STALE_QUEUE"; then
    say "Removing stale queue ${STALE_QUEUE}"
    run_cmd "$LPADMIN" -x "$STALE_QUEUE" || say "Could not remove ${STALE_QUEUE}"
  else
    say "No stale queue ${STALE_QUEUE}"
  fi
}

tail_log() {
  report_line "----- last lines of ${LOG} -----"
  tail -n 40 "$LOG" || true
  report_line "-----"
}

main_install() {
  local user_arg="${1:-}"
  local hw final installed
  check_platform
  check_root
  require_perl
  init_log
  resolve_tools
  say "Remax Secure Printer installer ${VERSION}"
  prompt_print_user "$user_arg"
  detect_console_user
  say "Print username: ${PRINT_USER}"
  say "Console user (owner): ${CONSOLE_USER}"
  say "Queue: ${QUEUE}"
  say "URI: ${URI}"
  log_preference_paths
  remove_stale_queue

  if ! find_driver_ppd; then
    if [[ -n "${REMAX_CANON_PKG_URL:-}" ]]; then
      say "Driver PPD not found; trying REMAX_CANON_PKG_URL"
      if ! install_driver_url "${REMAX_CANON_PKG_URL}"; then
        print_driver_help | tee -a "$LOG"
        D_DRIVER="Canon package install failed and CNMCIRAC5235S2 is still missing"
        finalize_report 1
      fi
      if ! find_driver_ppd; then
        print_driver_help | tee -a "$LOG"
        D_DRIVER="Package ran but CNMCIRAC5235S2 PPD is still not installed"
        finalize_report 1
      fi
    else
      print_driver_help | tee -a "$LOG"
      D_DRIVER="Canon iR-ADV C5235/5240 PS PPD (CNMCIRAC5235S2) is not installed"
      finalize_report 1
    fi
  fi

  say "Using driver PPD ${DRIVER_PPD_PATH}"
  if ! stage_driver; then
    D_DRIVER="Could not stage ${DRIVER_PPD_PATH}"
    finalize_report 1
  fi
  say "Validating NickName and ModelName (C5235 and 5240)"
  if ! canon_ppd validate-driver "$STAGED_DRIVER" >>"$LOG" 2>&1; then
    D_DRIVER="Staged PPD is not Canon iR-ADV C5235/5240 PS. See ${LOG}"
    say "Refusing to install a PPD whose NickName/ModelName are not C5235/5240."
    finalize_report 1
  fi

  say "Creating or updating queue ${QUEUE}"
  if ! attach_ppd "$STAGED_DRIVER"; then
    tail_log
    D_QUEUE="lpadmin failed while creating ${QUEUE}"
    finalize_report 1
  fi

  hw="${WORKDIR}/hardware.ppd"
  say "Patching cassette, finisher, and one-sided defaults"
  if ! canon_ppd patch-hardware "$STAGED_DRIVER" "$hw" >>"$LOG" 2>&1; then
    D_CASSETTE="Could not patch hardware defaults on the staged PPD. See ${LOG}"
    finalize_report 1
  fi
  say "Attaching hardware-patched PPD with lpadmin -P"
  if ! attach_ppd "$hw"; then
    tail_log
    finalize_report 1
  fi
  say "Applying lpadmin -o CNSrcOption, CNFinisher, and CNDuplex"
  if ! apply_options; then
    tail_log
    finalize_report 1
  fi

  installed="$(installed_ppd_path)"
  if ! ppd_has_defaults "$installed"; then
    say "Defaults missing after lpadmin -o; re-attaching the hardware PPD"
    if ! attach_ppd "$hw"; then
      tail_log
      finalize_report 1
    fi
  fi
  if ! ppd_has_defaults "$installed"; then
    say "Cassette / finisher / one-sided defaults are not in the installed PPD."
    run_ppd_verify || true
    finalize_report 1
  fi
  say "Hardware defaults are present in the installed PPD"

  final="${WORKDIR}/final.ppd"
  say "Writing Enter Name into colon-form *%INFO_PrPr"
  if ! canon_ppd patch-info "$hw" "$final" "$PRINT_USER" "$CONSOLE_USER" >>"$LOG" 2>&1; then
    D_ENTER="Could not build INFO_PrPr. See ${LOG}"
    finalize_report 1
  fi
  say "Attaching Enter Name PPD with lpadmin -P"
  if ! attach_ppd "$final"; then
    tail_log
    finalize_report 1
  fi
  if ! ppd_has_defaults "$installed"; then
    say "Defaults dropped when Enter Name was attached; re-attaching once"
    if ! attach_ppd "$final"; then
      tail_log
      finalize_report 1
    fi
  fi
  if ! ppd_has_defaults "$installed"; then
    say "Defaults are missing after the Enter Name attach."
    run_ppd_verify || true
    finalize_report 1
  fi
  say "Defaults still present after Enter Name attach"

  if [[ "${REMAX_TEST_MODE:-}" != "1" ]]; then
    if command -v cupsenable >/dev/null 2>&1; then
      cupsenable "$QUEUE" >>"$LOG" 2>&1 || true
    fi
    if command -v cupsaccept >/dev/null 2>&1; then
      cupsaccept "$QUEUE" >>"$LOG" 2>&1 || true
    fi
  fi

  run_ppd_verify || true
  refresh_queue_checks || true
  if overall_pass; then
    finalize_report 0
  fi
  finalize_report 1
}

MODE="install"
USER_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      MODE="help"
      ;;
    --self-test)
      MODE="self-test"
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      USER_ARG="$1"
      ;;
  esac
  shift
done

case "$MODE" in
  help)
    usage
    exit 0
    ;;
  self-test)
    require_perl
    canon_ppd self-test
    exit $?
    ;;
  install)
    main_install "$USER_ARG"
    ;;
esac
