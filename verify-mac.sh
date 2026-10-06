#!/bin/bash
# Read-only check of the RemaxSecure queue. Does not change CUPS.
#
#   curl -fsSL https://raw.githubusercontent.com/ItsErod/canon-secure-print/main/verify-mac.sh | bash
#   sudo bash verify-mac.sh
#
# Optional: REMAX_PRINT_USER and REMAX_CONSOLE_USER must match the PPD
# when set. Without them, the script still checks Canon-format Enter Name
# and prints the decoded user and owner.

if [ -z "${BASH_VERSION:-}" ]; then
  echo "Run this verifier with bash, not sh." >&2
  exit 1
fi

set -u
set -o pipefail

VERSION="1.0.1"
RAW_VERIFY_URL="https://raw.githubusercontent.com/ItsErod/canon-secure-print/main/verify-mac.sh"
QUEUE="RemaxSecure"
STALE_QUEUE="RemaxSecure_COLOUR"
URI="${REMAX_PRINTER_URI:-lpd://172.16.105.21/RemaxSecure}"

LOG=""
SUPPORT=""
WORKDIR=""
CANON_EMBED_FILE=""
LPSTAT=""
FOUND_USER=""
FOUND_OWNER=""
EXPECT_USER="${REMAX_PRINT_USER:-}"
EXPECT_OWNER="${REMAX_CONSOLE_USER:-}"

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
  # macOS bash 3.2 leaves BASH_SOURCE unset when this script is piped
  # (curl | bash). A bare ${BASH_SOURCE[0]} under set -u aborts the shell
  # even inside `if`, so the verifier would exit before the VERIFY REPORT.
  src="${BASH_SOURCE[0]-}"
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
Remax Secure Printer verifier ${VERSION} (read only)

  curl -fsSL ${RAW_VERIFY_URL} | bash
  sudo bash verify-mac.sh
  REMAX_PRINT_USER='tsiogase' bash verify-mac.sh
  bash verify-mac.sh --self-test

No printers are added or changed. Exit status is non-zero if any required
check fails.
EOF
}

require_perl() {
  if ! command -v perl >/dev/null 2>&1; then
    echo "perl is required. It ships with macOS." >&2
    exit 1
  fi
  if ! perl -MCompress::Zlib -e '1' >/dev/null 2>&1; then
    echo "Perl Compress::Zlib is required. It ships with macOS." >&2
    exit 1
  fi
}

init_log() {
  WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/remax-verify.XXXXXX")"
  if [[ -n "${REMAX_LOG:-}" ]]; then
    LOG="${REMAX_LOG}"
  else
    LOG="/tmp/RemaxSecurePrinterVerify-mac.log"
  fi
  if [[ -n "${REMAX_SUPPORT_DIR:-}" ]]; then
    SUPPORT="${REMAX_SUPPORT_DIR}"
  else
    SUPPORT="/Library/Application Support/RemaxSecurePrinter"
  fi
  {
    echo "Remax Secure Printer verifier ${VERSION}"
    echo "date: $(date)"
    echo "read-only: yes"
  } > "$LOG"
}

installed_ppd_path() {
  printf '%s/%s.ppd' "${REMAX_CUPS_PPD_DIR:-/etc/cups/ppd}" "$QUEUE"
}

resolve_lpstat() {
  if [[ -n "${REMAX_LPSTAT:-}" ]]; then
    LPSTAT="${REMAX_LPSTAT}"
  elif command -v lpstat >/dev/null 2>&1; then
    LPSTAT="$(command -v lpstat)"
  else
    LPSTAT=""
  fi
}

detect_owner_expectation() {
  local u="" s=""
  if [[ -n "$EXPECT_OWNER" ]]; then
    return 0
  fi
  if [[ "${REMAX_TEST_MODE:-}" == "1" ]]; then
    return 0
  fi
  if command -v scutil >/dev/null 2>&1; then
    u="$(scutil <<< "show State:/Users/ConsoleUser" 2>/dev/null | awk '/Name :/ { print $3; exit }')"
  fi
  if [[ -z "$u" || "$u" == "loginwindow" || "$u" == "root" ]]; then
    s="$(stat -f '%Su' /dev/console 2>/dev/null || true)"
    if [[ -n "$s" && "$s" != "root" && "$s" != "loginwindow" ]]; then
      u="$s"
    fi
  fi
  if [[ "$u" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then
    EXPECT_OWNER="$u"
    say "Comparing owner to console user ${EXPECT_OWNER}"
  else
    say "Console user not detected; owner will be reported but not compared"
  fi
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
  if [[ -n "$LPSTAT" ]] && "$LPSTAT" -p "$QUEUE" >/dev/null 2>&1 && [[ -f "$installed" ]]; then
    R_QUEUE="PASS"
    D_QUEUE="${QUEUE} is installed (${installed})"
  elif [[ -z "$LPSTAT" && -f "$installed" ]]; then
    R_QUEUE="PASS"
    D_QUEUE="${installed} exists (lpstat not available)"
  else
    R_QUEUE="FAIL"
    D_QUEUE="${QUEUE} is not installed"
  fi
  got=""
  if [[ -n "$LPSTAT" ]]; then
    got="$("$LPSTAT" -v "$QUEUE" 2>>"$LOG" || true)"
    got="$(printf '%s\n' "$got" | sed -n 's/^device for [^:]*:[[:space:]]*//p' | head -n 1 | tr -d '\r')"
  fi
  if [[ "$got" == "$URI" ]]; then
    R_URI="PASS"
    D_URI="$got"
  else
    R_URI="FAIL"
    D_URI="expected ${URI}, lpstat returned '${got:-nothing}'"
  fi
  if [[ -n "$LPSTAT" ]] && "$LPSTAT" -p "$STALE_QUEUE" >/dev/null 2>&1; then
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
  report_line "======== Remax Secure Printer VERIFY REPORT ========"
  report_line "No changes made."
  report_line "RESULT:      ${result}"
  report_line "QUEUE:       ${R_QUEUE}  ${D_QUEUE}"
  report_line "URI:         ${R_URI}  ${D_URI}"
  report_line "DRIVER:      ${R_DRIVER}  ${D_DRIVER}"
  report_line "CASSETTE:    ${R_CASSETTE}  ${D_CASSETTE}"
  report_line "FINISHER:    ${R_FINISHER}  ${D_FINISHER}"
  report_line "SIDES:       ${R_SIDES}  ${D_SIDES}"
  report_line "ENTER NAME:  ${R_ENTER}  ${D_ENTER}"
  report_line "STALE QUEUE: ${R_STALE}  ${D_STALE}"
  if [[ -n "$FOUND_USER" || -n "$FOUND_OWNER" ]]; then
    report_line "Decoded:     user ${FOUND_USER:-?}  owner ${FOUND_OWNER:-?}"
  fi
  report_line "Log:         ${LOG}"
  report_line "===================================================="
}

copy_log() {
  if mkdir -p "$SUPPORT" 2>/dev/null; then
    cp -f "$LOG" "${SUPPORT}/RemaxSecurePrinterVerify-mac.log" 2>/dev/null || true
  fi
}

main_verify() {
  local installed out
  require_perl
  init_log
  resolve_lpstat
  detect_owner_expectation
  say "Remax Secure Printer verifier ${VERSION} (read only)"
  installed="$(installed_ppd_path)"
  if [[ ! -f "$installed" ]]; then
    D_DRIVER="PPD not found: ${installed}"
    D_QUEUE="${QUEUE} is not installed"
    if [[ ! -r "$(dirname "$installed")" && "${REMAX_TEST_MODE:-}" != "1" ]]; then
      report_line "Cannot read $(dirname "$installed"). Re-run with sudo:"
      report_line "  curl -fsSL ${RAW_VERIFY_URL} | sudo bash"
    fi
    refresh_queue_checks || true
    print_report
    copy_log || true
    exit 1
  fi
  if [[ ! -r "$installed" ]]; then
    report_line "Cannot read ${installed}. Re-run with sudo:"
    report_line "  curl -fsSL ${RAW_VERIFY_URL} | sudo bash"
    exit 1
  fi
  out="${WORKDIR}/verify.out"
  if [[ -n "$EXPECT_USER" && -n "$EXPECT_OWNER" ]]; then
    canon_ppd verify "$installed" "$EXPECT_USER" "$EXPECT_OWNER" >"$out" 2>>"$LOG" || true
  elif [[ -n "$EXPECT_USER" ]]; then
    canon_ppd verify "$installed" "$EXPECT_USER" >"$out" 2>>"$LOG" || true
  elif [[ -n "$EXPECT_OWNER" ]]; then
    canon_ppd verify "$installed" "" "$EXPECT_OWNER" >"$out" 2>>"$LOG" || true
  else
    canon_ppd verify "$installed" >"$out" 2>>"$LOG" || true
  fi
  parse_canon_output "$out"
  refresh_queue_checks || true
  print_report
  copy_log || true
  if overall_pass; then
    exit 0
  fi
  exit 1
}

MODE="verify"
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
      echo "Unexpected argument: $1" >&2
      usage >&2
      exit 2
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
  verify)
    main_verify
    ;;
esac
