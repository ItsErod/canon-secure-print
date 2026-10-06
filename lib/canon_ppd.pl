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
