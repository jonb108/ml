#!/usr/bin/env perl
use strict;
use warnings;

use lib '.';

=comment

TODO:
    timestamp the log
    log is for today.  how to see other days?
    add edit function to ml_admin

    cron job to save mysql data
        and vb brigades in vb

    RN - no spaces, check for existence

    date for new messages cannot beyond tomorrow?

    protect against sql attacks - how?
        translate quotes into html entities

    video

=cut

sub JON {
    open my $out, '>>', '/tmp/jon';
    print {$out} "@_\n";
    close $out;
}

my $max = 60;   # how many to show before 'Show All'?

use CGI;
use CGI::Carp qw/
    fatalsToBrowser
    warningsToBrowser
/;
use List::MoreUtils qw/
    uniq
/;
my $q = CGI->new();
my $cookie = $q->cookie('message_library');
my $mobile = $ENV{HTTP_USER_AGENT} =~ m{iPhone|Android}xms;
my %P = $q->Vars();
my $cmd = $P{cmd};
my $meta_cookie;

use DBI;
my $dbh = DBI->connect(
    'dbi:mysql:logical9_moliere:host2047.hostmonster.com',
    'logical9_sahadev',
    'yoG.Sit801',
    { RaiseError => 1, AutoCommit => 1 }
) or die "cannot connect to database\n";

# two used in two different places so we prepare now
my $get_msg_sth = $dbh->prepare(<<'EOS');

        SELECT *
          FROM messages
         WHERE id = ?

EOS
my $upd_dt_sth = $dbh->prepare(<<'EOS');

    UPDATE messages
       SET mdate = ?
     WHERE id = ?

EOS

use Date::Simple qw/
    date
    today
/;

my $msg = '<p>';
my $result = '';
my $space = '&nbsp;' x 4;
my $cp = 2;
my $ncol = 3;
# EDIT!
my $cgi_bin_ml = 'https://vbmessages.org/cgi-bin/ml';
my $tab = $P{tab} || 'messages';

sub repl_quote {
    my ($s) = @_;
    $s =~ s{'}{&#39;}xmsg;    # hack to avoid quoting issues
    $s =~ s{"}{&#34;}xmsg;    # hack to avoid quoting issues
    return $s;
}

sub mixed {
    return join ' ', map { ucfirst lc } split ' ', shift;
}

sub log_it {
    open my $out, '>>', 'ml_log';
    print {$out} "@_\n";
    close $out;
}

sub trim {
    my ($s) = @_;
    $s =~ s{\A \s*|\s* \z}{}xmsg;
    $s =~ s{\s{2,}}{ }xmsg;
    $s;
}

sub end_html {
    print <<'EOH';
</body>
</html>
EOH
}

sub red {
    "<span class=red>$_[0]</span>";
}

sub gray {
    "<span class=gray>$_[0]</span>";
}

sub green {
    "<span class=green>$_[0]</span>";
}

sub msg_green {
    "<span class=msg_green>$_[0]</span>";
}

sub meta {
    my ($href, $with_date) = @_;
    my $bn = $href->{brigade_name} || '';
    my $ct = $href->{city} || '';
    my $st = $href->{state} || '';
    my $meta = '';
    if ($bn || $ct || $st) {
        if ($bn) {
            $meta .= $bn;
        }
        if ($ct) {
            if ($meta) {
                $meta .= ' - ';
            }
            $meta .= $ct;
        }
        if ($st) {
            if ($meta) {
                $meta .= ', ';
            }
            $meta .= $st;
        }
        if ($with_date) {
            $meta .= " on " . date($href->{mdate})->format("%D");
        }
        $meta = "$meta<br>";
    }
    return $meta;
}

# ask for an import file
sub import1 {
    my ($bn, $ct, $st) = ('') x 3;
    if ($cookie) {
        ($bn, $ct, $st) = split /[|]/, $cookie;
    }
    print <<"EOH";
<h3>Import Messages</h3>
<form method=post enctype="multipart/form-data"> 
<table cellpadding=5>
<tr>
<td align=right>CSV File:</td>
<td><input type=file name=import_file></td>
</tr>
<tr>
<td align=right>Brigade Name</td>
<td><input type=text name=brigade_name size=37 value='$bn'><span class=opt_help>(optional)</span>
</td>
</tr>
<tr>
<td align=right>City</td>
<td><input type=text name=city size=26 value='$ct'>
&nbsp;&nbsp;
State <input 
style='text-transform: uppercase; width: 18mm;'
type=text name=state maxlength=2 value='$st'>
<span class=opt_help>(optional)</span>
</td>
</tr>
<tr>
<td></td>
<td><input id=sub type=submit style='background: lightgreen' value='Import'></td>
</tr>
</table>
</form>
EOH
    exit;
}

# process the import file
sub import2 {
    my $tmp_fname = "/tmp/msg_upload.csv";
    my $fh = $q->upload('import_file');
    if (! defined $fh) {
        $msg = red("No upload :(");
        return;
    }
    # Upgrade the handle to one compatible with IO::Handle:
    my $fh_handle = $fh->handle;
    my $out;
    if (!open $out, '>', $tmp_fname) {
        $msg = red("Cannot create $tmp_fname");
        return;
    }
    binmode($out);
    my $buffer;
    while (my $n = $fh_handle->read($buffer, 1024)) {
        print {$out} $buffer;
    }
    close $out;
    close $fh;
    close $fh_handle;
    my $in;
    if (!open $in, '<', $tmp_fname) {
        print "Cannot open $tmp_fname\n";
        return;
    }
    my $get_message_sth = $dbh->prepare(<<'EOS');

        SELECT id, mdate
          FROM messages
         WHERE message = ?
      ORDER BY mdate desc

EOS
    my $add_sth = $dbh->prepare(<<'EOS');

        INSERT
          INTO messages
               (mdate, message,
                brigade_name, city, state,
                topics_desc)
        VALUES (?, ?,
                ?, ?, ?,
                '')

EOS
    my $today = today()->as_d8();
    my $brigade_name = trim($P{brigade_name}) || '';
    my $city = trim($P{city}) || '';
    my $state = trim(uc $P{state}) || '';
    $meta_cookie = $q->cookie(
        -name    => 'message_library',
        -value   => "$brigade_name|$city|$state",
        -expires => '+20y',
    );
    my @mids;
    my $n = 0;
    my $duplicate = 0;
    my $dt_upd = 0;
    my $status_msg;
    LINE:
    while (my $line = <$in>) {
        $line =~ s{[\r\n]+}{}xms;   # remove end of line characters
        $line = uc $line;           # force upper case
        next LINE unless $line =~ m{\S}xms;
        if (index($line, ',') < 0) {
            # no comma - just a message
            # date will be today
            my $message = uc trim $line;
            $message =~ s{\A " (.*) "\z}{$1}xms;
            $get_message_sth->execute($message);
            if (my $href = $get_message_sth->fetchrow_hashref()) {
                # duplicate?  Is it older?
                if ($href->{mdate} < $today) {
                    # update the date
                    $upd_dt_sth->execute($today, $href->{id});
                    ++$dt_upd;
                }
                else {
                    ++$duplicate;
                }
            }
            else {
                $add_sth->execute($today, $message,
                                  $brigade_name, $city, $state);
                push @mids, $dbh->last_insert_id(undef, undef,
                                                 'messages', undef);
                ++$n;
                log_it("imported $message");
            }
        }
        elsif ($line =~ m{\A ([^,]+) , (.*) \z}xms) {
            my $dt = trim $1;
            my $message = trim $2;
            $message =~ s{\A " (.*) "\z}{$1}xms;
            my $date = date($dt);
            if ($date) {
                $get_message_sth->execute($message);
                if (my $href = $get_message_sth->fetchrow_hashref()) {
                    # duplicate?  Is it older?
                    my $d8 = $date->as_d8();
                    if ($href->{mdate} < $d8) {
                        # update the date
                        $upd_dt_sth->execute($d8, $href->{id});
                        ++$dt_upd;
                    }
                    else {
                        ++$duplicate;
                    }
                }
                else {
                    $add_sth->execute($date->as_d8(), $message,
                                      $brigade_name, $city, $state);
                    push @mids, $dbh->last_insert_id(undef, undef,
                                                     'messages', undef);
                    ++$n;
                    log_it("imported $message");
                }
            }
            elsif (lc $dt ne 'date') {
                $status_msg .= red("Invalid date:") . " $dt - message not imported<br>";
            }
        }
    }
    close $in;
    if ($n || $duplicate || $dt_upd) {
        my $pl = $n == 1? '': 's';
        log_it("import $n new, $duplicate dup, $dt_upd dt");
        if ($duplicate) {
            my $pl = $duplicate == 1? '': 's';
            $status_msg .= red("$duplicate duplicate message$pl ignored<br>");
        }
        if ($dt_upd) {
            my $pl = $dt_upd == 1? '': 's';
            $status_msg .= red("$dt_upd message date$pl updated<br>");
        }
        $status_msg .= "$n new message$pl imported<br>";
        if ($n) {
            my $mids = "@mids[1..$#mids]";
            init();
            disp_topics($mids[0],
                        0, 'description asc', 0, $mids, $status_msg);
        }
        else {
            $msg .= $status_msg;
        }
    }
    else {
        $msg .= "0 messages imported";
        $tab = 'messages';
    }
}

#
# this routine returns if there are no messages without a topic
# otherwise it ends up exiting in the routine disp_topics.
#
sub no_topics {
    my $search_sth = $dbh->prepare(<<"EOS");

        SELECT id
          FROM messages
         WHERE topics_desc = ''
      ORDER BY mdate desc

EOS
    $search_sth->execute();
    log_it("search for no topics");
    my @mids;
    my $first_mid;
    while (my $href = $search_sth->fetchrow_hashref()) {
        my $mid = $href->{id};
        if (! $first_mid) {
            $first_mid = $mid;
        }
        else {
            push @mids, $mid;
        }
    }
    if (!$first_mid) {
        return;
    }
    my $nmids = @mids;
    my $pl = $nmids == 1? '': 's';
    init();
    disp_topics($first_mid,
                0, 'description asc', 0, "@mids", "$nmids more message$pl");
}

sub record_count {
    my ($table) = @_;
    my $count_sth;
    if ($table eq 'state') {
        $count_sth = $dbh->prepare(<<"EOS");
            SELECT count(distinct state) as count
              FROM messages
EOS
    }
    elsif ($table eq 'city') {
        # Oaks, CA and Oaks, PA   !!
        $count_sth = $dbh->prepare(<<"EOS");
            SELECT count(distinct concat(state, city)) as count
              FROM messages
EOS
    }
    else {
        $count_sth = $dbh->prepare(<<"EOS");
            SELECT count(*) as count
              FROM $table
EOS
    }
    $count_sth->execute();
    my $href = $count_sth->fetchrow_hashref();
    return $href->{count};
}

sub city_state {
    my $cs_sth = $dbh->prepare(<<'EOS');

        SELECT DISTINCT CONCAT(state, ' - ', city) as cs, state, city
          FROM messages
      ORDER BY cs

EOS
    my $cnt_sth = $dbh->prepare(<<'EOS');
            
            SELECT count(*)
              FROM messages
             WHERE state = ? and city = ?

EOS
    $cs_sth->execute();
    $result = "State, City and # of messages.&nbsp;&nbsp;&nbsp;Click on the numbers to see the messages.<p><div style='margin-left: .5in;'>";
    while (my $href = $cs_sth->fetchrow_hashref()) {
        my $state = $href->{state};
        my $city = $href->{city};
        $cnt_sth->execute($state, $city);
        my ($count) = $cnt_sth->fetchrow_array();
        my $url = "$cgi_bin_ml?cmd=search_plus2&city_search=$city+&state_search=$state&exact=1";
        $result .= "$state - $city <a href='$url'>$count</a><br>\n";
    }
    $result .= "</div>";
}

sub brigade_names {
    my $bn_sth = $dbh->prepare(<<'EOS');

        SELECT DISTINCT CONCAT(state, ' - ', city, ' - ', brigade_name) as bn
          FROM messages
      ORDER BY bn
EOS
    $bn_sth->execute();
    while (my $href = $bn_sth->fetchrow_hashref()) {
        $result .= $href->{bn} . '<br>';
    }
    $result .= '<br>';
}

sub show_counts {
    my $rt = { align => 'right'};
    $result .= $q->ul($q->table({ cellpadding => 5 },
                   $q->Tr($q->td($rt, record_count('messages')),
                          $q->td(' messages')
                         ),
                   $q->Tr($q->td($rt, record_count('topics')),
                          $q->td(' topics')
                         ),
                   $q->Tr($q->td($rt, record_count('message_topic')),
                          $q->td(' topics assigned to messages')
                         ),
                   $q->Tr($q->td($rt, record_count('state')),
                          $q->td(' states')
                         ),
                   $q->Tr($q->td($rt, record_count('city')),
                          $q->td(' cities')
                         ),
               ));
}

sub msg_fmt {
    my ($href) = @_;
    my $mid = $href->{id};
    my $adj = "$cgi_bin_ml?cmd=adjust_topics&message_id=$mid";
    my $align = 'top';
    $q->Tr(
        $q->td({ valign => $align, width => '9%',
                 style => 'white-space: nowrap;' },
               gray(date($href->{mdate})->format('%D'))
        ),
        $q->td({ valign => $align },
               "<a class=black href='$adj'>"
             . msg_green($href->{message})
             . ($mobile? '<br>': $space)
             . "$href->{topics_desc}</a>")
    );
}

# given a message id
# get text of the message for the header
# call disp_topics which will:
# get current topics for the message
# display all topics with checked ones checkbox name=topic_ids
# hidden param message id
# hidden all current topics space separated
# action: ml?cmd=adjust_topics2
# which will:
#   first clear all current topics for the message
#       in message_topic table
#   and decrement topics.count fields
# then call topic_ids sub to finish
#
sub adjust_topics {
    my ($message_id) = $P{message_id};
    $get_msg_sth->execute($message_id);
    my $href = $get_msg_sth->fetchrow_hashref();
    log_it("adjust topic for $href->{message}");
    disp_topics($message_id,
                1, 'description asc', 0);
}

#
# called in 5 ways:
#     1) new message - to add topics
#     2) existing message - to add/delete topics
#     3) display topics for their counts
#           and for choosing a topic (via a link)
#           to find messages that have that topic.
#           display the topics in one of two orders.
#     4) after an import - with a list of other
#            message ids (space separated)
#     5) After a 'no topics' search
#
#     If the first parameter is 0 we only display the topics
#     If the first parameter is an href it contains the message
#     Otherwise the first paramter is a message id and we
#     get the message with $get_msg_sth.
#
sub disp_topics {
    my ($first,
        $old, $order, $links, $mids, $status_msg) = @_;

    my ($message, $message_id);
    my $meta = '';
    my $href = 0;
    if (ref $first) {
        $href = $first;
        $message_id = $href->{id};
    }
    elsif ($first != 0) {
        $message_id = $first;
        $get_msg_sth->execute($message_id);
        $href = $get_msg_sth->fetchrow_hashref();
    }
    if ($href) {
        $message = $href->{message};
        $meta = meta($href, 1);
        if ($meta) {
            $meta = "<br>$meta";;
        }
    }
    my %is_current_topic;
    my $current_topics;
    if ($old) {
        # there may be some current topics on this message ...
        #
        my $get_topics_sth = $dbh->prepare(<<'EOS');

            SELECT topics.id
              FROM topics, message_topic
             WHERE message_topic.message_id = ?
                   AND topics.id = message_topic.topic_id

EOS
        $get_topics_sth->execute($message_id);
        while (my $href = $get_topics_sth->fetchrow_hashref()) {
            $is_current_topic{$href->{id}} = 1;
        }
        $current_topics = join ',', keys %is_current_topic;
    }
    if (! $links) {
        my $message2 = repl_quote($message);
        print <<"EOH";
$status_msg
<p>
<span class='green pointer' onclick='copy_to_clipboard("$message2")'>$message2</span>
<span style='color: green; margin-left: .3in;' id=copied></span>
$meta
<form method=post id=adjTopic action=$cgi_bin_ml>
<input type=hidden name=cmd value=adjust_topics2>
<input type=hidden name=message_id value=$message_id>
<input type=hidden name=current_topics value='$current_topics'>
EOH
        if ($mids) {
            print <<"EOH";
<input type=hidden name=mids value='$mids'>
EOH
        }
    }
    my $n_topics_sth = $dbh->prepare(<<"EOS");
        
        SELECT count(*)
          FROM topics

EOS
    $n_topics_sth->execute();
    my $aref = $n_topics_sth->fetchrow_arrayref();
    my $n_topics = $aref->[0];
    my $per_col = int ($n_topics/$ncol);
    my $all_topics_sth = $dbh->prepare(<<"EOS");

        SELECT id, description, count
          FROM topics
      ORDER BY $order

EOS
    $all_topics_sth->execute();
    print "<table cellpadding=5><tr><td valign=top>\n";
    my $n = 0;
    while (my $href = $all_topics_sth->fetchrow_hashref()) {
        my $tid = $href->{id};
        my $desc = $href->{description};
        if ($links) {
            print "<a href='$cgi_bin_ml?topic_search=$tid'>"
                . "$desc</a> $href->{count}<p class=tt>\n";
        }
        else {
            my $checked = $old && $is_current_topic{$tid}? ' checked': '';
            print "<label>"
                . "<input type=checkbox name=topic_ids value=$tid$checked>"
                . " $desc</label><p class=tt>\n";
                # how to make this less spaced out??
        }
        ++$n;
        if ($n >= $per_col) {
            print "</td><td valign=top>\n";
            $n = 0;
        }
    }
    if ($n != 0) {
        if (! $links) {
            print "<div style='margin-top: 20mm'>";
            print "<input type=submit class=sub value='Submit'>";
            print "</div>";
        }
        print "</td>\n";
        $n = 0;
    }
    print <<'EOH';
</tr></table>
EOH
    if (! $links) {
        print <<"EOH";
<p>
<input type=submit class=sub value="Submit">
</form>
EOH
    }
    end_html();
    exit;
}

# first clear any current topics for the message
#     in message_topic table
# and decrement topics.count fields
# then add new ones
#
# Journaling is used here.
#
sub adjust_topics2 {
    my $message_id = $P{message_id};
    my $current_topics = $P{current_topics};
    $dbh->begin_work;       # commit when all is well
    if ($current_topics) {
        #
        # clear existing topics
        #
        my $clear_topics_sth = $dbh->prepare(<<'EOS');

        DELETE
          FROM message_topic
         WHERE message_id = ?

EOS
        $clear_topics_sth->execute($message_id);

        # and decrement the counts in topics records
        #
        my $decr_topic_counts_sth = $dbh->prepare(<<"EOS");

        UPDATE topics
           SET count = count - 1
         WHERE id IN ($current_topics)

EOS
        $decr_topic_counts_sth->execute();
    }
    #
    # now for the new topics
    #
    my @topic_ids = $q->param('topic_ids');
    my $topics_desc = '';

    if (@topic_ids) {
        my $mt_sth = $dbh->prepare(<<'EOS');

            INSERT
              INTO message_topic
                   (message_id, topic_id)
            VALUES (?, ?)

EOS
        for my $tid (@topic_ids) {
            $mt_sth->execute($message_id, $tid);
        }
        my $csv_topic_ids = join ',', @topic_ids;
        my $bump_sth = $dbh->prepare(<<"EOS");

            UPDATE topics
               SET count = count + 1
             WHERE id IN ($csv_topic_ids)

EOS
        $bump_sth->execute();
        my $topics_desc_sth = $dbh->prepare(<<"EOS");

            SELECT description
              FROM topics
             WHERE id IN ($csv_topic_ids)
          ORDER BY description

EOS
        $topics_desc_sth->execute();
        my @topics_desc;
        while (my $aref = $topics_desc_sth->fetchrow_arrayref()) {
            push @topics_desc, $aref->[0];
        }
        $topics_desc = join(', ', uniq sort @topics_desc);
    }
    my $message_topics_desc_sth = $dbh->prepare(<<'EOS');

        UPDATE messages
           SET topics_desc = ?
         WHERE id = ?

EOS
    $message_topics_desc_sth->execute($topics_desc, $message_id);
    # everything is complete so ...
    $dbh->commit;

    log_it("set topic: $topics_desc");
    if ($P{mids}) {
        # we are in the middle of an import
        my @mids = split ' ', $P{mids};
        my $mid = shift @mids;
        my $nmids = @mids;
        my $pl = $nmids == 1? '': 's';
        my $status_msg = $nmids != 0? "$nmids more message$pl": 'This is the last message.';
        $get_msg_sth->execute($mid);
        my $href = $get_msg_sth->fetchrow_hashref();
        init();
        disp_topics($mid,
                    0, 'description asc', 0, "@mids", $status_msg);
    }
    else {
        $tab = 'messages';
    }
}

sub add_message {
    my ($mess, $d8) = @_;    # both optional
    $mess ||= '';
    $mess = repl_quote($mess);
    my $dt;
    if ($d8) {
        $dt = date($d8)->format('%D');
    }
    my ($bn, $ct, $st) = ('') x 3;
    if ($cookie) {
        ($bn, $ct, $st) = split /[|]/, $cookie;
    }
    print <<"EOH";
<h3>Adding a message</h3>
<form method=post action=$cgi_bin_ml>
<table cellpadding=5>
<tr>
<td align=right>Date</td>
<td><input type=text name=message_date id=date size=8 value='$dt' autofocus style='text-transform: uppercase;'>
<span class=info onclick="javascript:show_date_help();">&#9432;</span><span class=opt_help2>(Date the message was displayed)</span>
</td>
</tr>
<tr>
<td align=right>Message</td>
<td><input style='text-transform: uppercase;' type=text name=new_message size=60 value='$mess'></td>
</tr>
<tr>
<td align=right>Brigade Name</td><td><input type=text name=brigade_name size=37 value='$bn'><span class=opt_help>(optional)</span></td>
</tr>
<tr>
<td align=right>City</td>
<td><input type=text name=city size=26 value='$ct'>
State <input style='text-transform: uppercase; width: 18mm;'
       type=text name=state maxlength=2 value='$st'>
       <span class=opt_help>(optional)</span>
</td>
</tr>
<tr>
<td></td>
<td><input type=submit class=sub value='Add'></td>
</tr>
</table>
</form>
EOH
    end_html();
    exit;
}

sub new_message {
    $tab = 'messages';
    # what about XXS?
    my $message = trim uc $P{new_message};
    if ($message !~ m{\S}xms) {
        return;
    }
    my $date = $P{message_date} || 't';
    my $dt = date($date);
    if (!$dt) {
        $msg .= red("Invalid date:") . " $date - message not added<p>";
        return;
    }
    # duplicate message?
    # if so, check the date.
    #
    my $get_message_sth = $dbh->prepare(<<'EOS');

        SELECT id, mdate
          FROM messages
         WHERE message = ?
      ORDER BY mdate desc

EOS
    $get_message_sth->execute($message);
    my $href = $get_message_sth->fetchrow_hashref();
    if ($href) {
        my $existing_dt = date($href->{mdate});
        if ($existing_dt > $dt) {
            $msg .= red("Duplicate message with older date:") . " $message<p>";
            return;
        }
        else {
            # update the date, don't add a duplicate
            $upd_dt_sth->execute($dt->as_d8(), $href->{id}); 
            return;
        }
    }
    my $add_message_sth = $dbh->prepare(<<'EOS');
        
        INSERT
          INTO messages
               (mdate, message, brigade_name, city, state, topics_desc)
        VALUES (?, ?,
                ?, ?, ?,
                '')

EOS
    my $brigade_name = trim($P{brigade_name}) || '';
    my $city = trim($P{city}) || '';
    my $state = trim(uc $P{state}) || '';
    $meta_cookie = $q->cookie(
        -name    => 'message_library',
        -value   => "$brigade_name|$city|$state",
        -expires => '+20y',
    );
    $add_message_sth->execute($dt->as_d8(), $message,
                              $brigade_name, $city, $state);
    log_it("added $message on " . $dt->as_d8()
          . " $brigade_name - $city - $state"
          );
    my $message_id = $dbh->last_insert_id(undef, undef, 'messages', undef);
    init();
    disp_topics($message_id,
                0, 'description asc', 0);
}

sub add_topic {
    print <<"EOH";
<h3>Adding topics</h3>
<style>
.pp {
    margin-bottom: 4mm;
}
</style>
<form method=post action=$cgi_bin_ml>
<input type=hidden name=cmd value=new_topic>
1 <input class=pp type=text name=new_topic1 size=40 autofocus><br>
2 <input class=pp type=text name=new_topic2 size=40 autofocus><br>
3 <input class=pp type=text name=new_topic3 size=40 autofocus><br>
4 <input class=pp type=text name=new_topic4 size=40 autofocus><br>
5 <input class=pp type=text name=new_topic5 size=40 autofocus><br>
<input type=submit class=sub value='Add'>
</form>
EOH
    end_html();
    exit;
}

sub new_topic {
    $tab = 'topics';
    my $get_topic_sth = $dbh->prepare(<<'EOS');

        SELECT id
          FROM topics
         WHERE description = ?

EOS
    my $add_topic_sth = $dbh->prepare(<<'EOS');

        INSERT
          INTO topics
               (description, count)
        VALUES (?, 0)

EOS
    my $nadded = 0;
    NEW_TOPIC:
    for my $i (1 .. 5) {
        my $new_topic = trim($P{"new_topic$i"});
        if (!$new_topic) {
            next NEW_TOPIC;
        }
        # mixed case
        $new_topic =~ s{^([a-z])}{uc $1}xmsge;
        $new_topic =~ s{[ ]([a-z])}{' ' . uc $1}xmsge;

        # ignore if duplicate
        $get_topic_sth->execute($new_topic);
        if ($get_topic_sth->fetchrow_array()) {
            $msg .= red("Duplicate topic:") . " $new_topic<p>";
            next NEW_TOPIC;
        }    
        $add_topic_sth->execute($new_topic);
        ++$nadded;
        log_it("added topic $new_topic");
    }
    $P{order} = 'description asc';
}

sub search_plus2 {
    my $exact = trim $P{exact};
    my $sdate = trim $P{start_date};
    my @where;
    if ($sdate) {
        my $dt = date($sdate);
        if ($dt) {
            $sdate = $dt->as_d8();
            push @where,  "mdate >= $sdate";
        }
        else {
            $msg .= red("Invalid date:") . " $sdate<p>";
            return;
        }
    }
    my $edate = $P{end_date};
    if ($edate) {
        my $dt = date($edate);
        if ($dt) {
            $edate = $dt->as_d8();
            push @where,  "mdate <= $edate";
        }
        else {
            $msg .= red("Invalid date:") . " $edate<p>";
            return;
        }
    }
    my $mess = trim uc $P{message_search};
    if ($mess) {
        push @where, "message like '%$mess%'"; 
    }
    my $brig = trim uc $P{brigade_name_search};
    if ($brig) {
        push @where, "brigade_name like '%$brig%'"; 
    }
    my $city = trim uc $P{city_search};
    if ($city) {
        push @where, $exact? "city = '$city'": "city like '%$city%'"; 
    }
    my $state = trim uc $P{state_search};
    if ($state) {
        push @where, $exact? "state = '$state'": "state like '%$state%'"; 
    }
    if (! @where) {
        $result = 'Nothing to search for!';
        return;
    }
    my $where = join(' AND ', @where);
    my $plus_sth = $dbh->prepare(<<"EOS");

        SELECT *
          FROM messages
         WHERE $where
      ORDER BY mdate desc, message asc

EOS
    $plus_sth->execute();
    my $n = 0;
    while (my $href = $plus_sth->fetchrow_hashref()) {
        ++$n;
        if ($mess) {
            $href->{message} =~ s{\Q$mess}
                                 {<span class=highlight>$mess</span>}xmsg;
        }
        $result .= msg_fmt($href);
        if (! $exact) {
            my $meta = meta($href);
            if ($meta) {
                $result .= $q->Tr($q->td('&nbsp;'),
                                  $q->td($meta)
                                 );
            }
        }
    }
    if ($n == 0) {
        $result = "No matching messages.";
    }
    else {
        $result = $q->table({ cellpadding => $cp}, $result);
        if ($exact) {
            # city, state search
            $result = "Messages from " . mixed($city) . ", $state<p>\n"
                    . $result;
        }
    }
}

sub search_plus {
    print <<"EOH";
<h3>Search Plus<span class=all_opt >(All fields are optional)</span></h3>
<form method=get action=$cgi_bin_ml>
<input type=hidden name=cmd value=search_plus2>
<table cellpadding=5>
<tr><td align=right>Start Date</td><td><input type=text name=start_date id=date size=8 autofocus style='text-transform: uppercase;'>
<span class=info onclick="javascript:show_date_help();">&#9432;</span></td></tr>
<tr><td align=right>End Date</td><td><input type=text name=end_date id=date size=8 autofocus style='text-transform: uppercase;'></td></tr>
<tr><td align=right>Message</td><td><input style='text-transform: uppercase;' type=text name=message_search size=40></td></tr>
<tr><td align=right>Brigade Name</td><td><input type=text name=brigade_name_search size=37></td></tr>
<tr><td align=right>City</td><td><input type=text name=city_search size=26>
State <input type=text name=state_search maxlength=2 style='text-transform: uppercase; width: 18mm;'></td></tr>
<tr><td></td><td><input type=submit class=sub value='Search'></td></tr>
</table>
</form>
EOH
    end_html();
    exit;
}

sub search_messages {
    my $term = trim uc $P{search_term};
    if ($term eq 'A') {
        init();
        add_message();
    }
    elsif ($term eq 'AT') {
        init();
        add_topic();
    }
    elsif($term eq 'CS' || $term eq 'BN') {
        log_it('city state');
        city_state();
        return;
    }
    elsif($term eq 'CT') {
        log_it('counts');
        show_counts();
        return;
    }
    elsif ($term eq 'D') {
        $tab = 'messages';
        $P{order} ='mdate desc, message asc';
        return;
    }
    elsif ($term eq 'S') {
        init();
        search_plus();
    }
    elsif ($term eq 'I') {
        init();
        import1();
    }
    elsif ($term eq 'M') {
        $tab = 'messages';
        $P{order} ='message asc';
        return;
    }
    elsif ($term eq 'NT') {
        no_topics();
        $tab = 'messages';
        $P{order} ='mdate desc, message asc';
        return;
    }
    elsif ($term eq 'T') {
        $tab = 'topics';
        $P{order} = 'description asc';
        return;
    }
    elsif ($term eq 'C') {
        $tab = 'topics';
        $P{order} = 'count desc';
        return;
    }
    $term =~ s{\A /}{}xms;      # so we CAN search for AT or A, ...
    my $where = $term eq 'NT'? "topics_desc = ''"
               :               "message like '%$term%'";
    my $search_sth = $dbh->prepare(<<"EOS");

        SELECT *
          FROM messages
         WHERE message like '%$term%'
      ORDER BY mdate desc, message asc

EOS
    $search_sth->execute();
    log_it("search for $term");
    $term =~ s{([?*.])}{[$1]}xmsg;
    $term =~ s{%}{.*}xmsg;
    my $n = 0;
    $result = '';
    while (my $href = $search_sth->fetchrow_hashref()) {
        ++$n;
        $href->{message} =~ s{($term)}
                             {<span class=highlight>$1</span>}xmsg;
        $result .= msg_fmt($href);
    }
    if ($n == 0) {
        $result = "No messages match '$term'.";
    }
    else {
        $result = $q->table({ cellpadding => $cp}, $result);
    }
}


sub topic_search {
    my $tid = $P{topic_search};
    my $get_topic_sth = $dbh->prepare(<<'EOS');

        SELECT *
          FROM topics
         WHERE id = ?

EOS
    $get_topic_sth->execute($tid);
    my $href = $get_topic_sth->fetchrow_hashref();
    my $description = $href->{description};
    my $topic_search_sth = $dbh->prepare(<<'EOS');

        SELECT messages.*
          FROM messages, message_topic
         WHERE messages.id = message_topic.message_id
               AND message_topic.topic_id = ?
      ORDER BY messages.mdate desc, messages.message asc

EOS
    $topic_search_sth->execute($tid);
    my $n = 0;
    while (my $href = $topic_search_sth->fetchrow_hashref()) {
        ++$n;
        $result .= msg_fmt($href);
    }
    if ($n == 0) {
        $result = "No messages about $description.";
    }
    else {
        $result = "Messages with topic ". green($description) . "<p>"
                . $q->table({ cellpadding => $cp }, $result);
    }
    log_it("topic search $description");
}

sub init {
    my $script = '';
    if ($tab eq 'messages') {
        $script = <<'EOSC';
<script>
function show_date_help() {
    newwin = window.open(
        'https://vbmessages.org/date_help.html', 'date help',
        'popup=true,height=350,width=400'
    );
    newwin.moveTo(600, 200);
    setTimeout(() => {
        document.getElementById('date').focus();
    }, 500);
}
function copy_to_clipboard(msg) {
    navigator.clipboard.writeText(msg);
    var el = document.getElementById('copied');
    el.innerHTML = 'copied';
    setTimeout(() => {
        el.innerHTML = "";
    }, 800);
}
</script>
EOSC
    }
    if ($meta_cookie) {
        print $q->header(-cookie => $meta_cookie);
    }
    else {
        print $q->header();
    }

    print <<"EOH";
<html>
<head>
<style>
.tt {   /* for the topic table */
    line-height: 5mm;
}
.all_opt {
    margin-left: 1.5in;
    color: green;
    font-size: 18pt;
    font-weight: normal;
}
.opt_help2 {
    margin-left: 1.2in;
    color: green;
}
.opt_help {
    position: absolute;
    left: 780;
    color: green;
}
.cur_sort {
    font-weight: bold;
}
.info {
    margin-left: .1in;
    font-size: 20pt;
    font-weight: bold;
    color: darkgreen;
    cursor: pointer;
}
body {
    margin: .3in;
    line-height: 12mm;
}
body, input, td {
    font-size: 18pt;
    font-family: Arial;
}
a {
    text-decoration: none;
    color: blue;
}
.left {
    margin-left: .6in;
}
.right {
    margin-right: 1in;
}
.big {
    font-size: 26pt;
    font-weight: bold;
}
.highlight {
    background: #ffff66;
}
.sub {
    background: lightgreen;
}
.red {
    color: red;
}
.green {
    color: green;
    font-size: 28pt;
    font-weight: bold;
}
.black {
    color: black;
}
.msg_green {
    color: green;
    font-size: 22pt;
    font-weight: bold;
}
.pointer {
    cursor: pointer;
}
.gray, .curs {
    color: #a0a0a0;
}
.curs {
    cursor: pointer;
    font-size: 18pt;
    font-weight: bold;
}
input[type='checkbox'] {
    -webkit-appearance:none;
    width:15px;
    height:15px;
    background:white;
    border-radius:4px;
    border:2px solid #555;
}
input[type='checkbox']:checked {
    background: lightgreen;
}
</style>
$script
</head>
<body>
<h1><a style='color:black' href=$cgi_bin_ml?tab=messages accesskey='v'>VB Message Library</a></h1>
EOH
}

if ($cmd eq 'add_message') {
    init();
    add_message();
}
elsif ($cmd eq 'add_from_vb') {
    init();
    add_message($P{message}, $P{d8});
}
elsif (exists $P{new_message}) {
    new_message();
}
elsif ($cmd eq 'add_topic') {
    init();
    add_topic();
}
elsif ($cmd eq 'new_topic') {
    new_topic();
}
elsif ($P{search_term}) {
    search_messages();
}
elsif ($P{search_plus}) {
    init();
    search_plus();
}
elsif ($cmd eq 'search_plus2') {
    search_plus2();
}
elsif ($cmd eq 'adjust_topics2') {
    adjust_topics2();
}
elsif ($P{topic_search}) {
    topic_search();
}
elsif ($cmd eq 'adjust_topics') {
    init();
    adjust_topics();
}
elsif ($cmd eq 'import') {
    init();
    import1();
}
elsif ($P{import_file}) {
    import2();
}

#
# fall through - one of two tabs
#
init();
if ($tab eq 'messages') {
    # messages home
    #
    
    my $order = $P{order} || 'mdate desc, message asc';
    my %sort_class;
    my ($sort) = $order =~ m{\A (\S+)}xms;
    $sort_class{$sort} = 'class=cur_sort';

    print <<"EOH";
<span class=big>Messages</span>
<a class=left href='$cgi_bin_ml?cmd=add_message'>Add Message</a>
<a class=left href='$cgi_bin_ml?cmd=import'>Import</a>
<a class=left href='$cgi_bin_ml?tab=topics&order=description+asc'>Topics</a>
<a target=_blank class=left href=/help.html accesskey='h'>Help</a>
$msg
<form action=$cgi_bin_ml>
Search for&nbsp;&nbsp;<input type=text name=search_term size=15 autofocus style='text-transform: uppercase'>
$space<a href='$cgi_bin_ml?tab=messages&order=mdate+desc,message+asc&no_limit=0'>Recent</a>
&nbsp;&nbsp;<a href='$cgi_bin_ml?search_term=cs'>Cities</a>
$space<a href='$cgi_bin_ml?search_term=ct'>Counts</a>
$space<a href='$cgi_bin_ml?search_plus=1'>Search+</a>
</form>
<p>
EOH
    if ($result) {
        print $result;
    }
    else {
        my $limit = $P{no_limit}? '': "LIMIT $max";
        # show all messages
        my $all_messages_sth = $dbh->prepare(<<"EOS");
            
            SELECT *
              FROM messages
          ORDER BY $order
                   $limit

EOS
        $all_messages_sth->execute();
        print "<table cellpadding=$cp>\n";
        my $n = 0;
        while (my $href = $all_messages_sth->fetchrow_hashref()) {
            print msg_fmt($href);
            ++$n;
        }
        print "</table>\n";
        if ($n && $limit) {
            print <<"EOH";
<p>
<a style='margin-left: 1.9in;' href='$cgi_bin_ml?tab=messages&order=$order&no_limit=1' accesskey='S'>Show All</a>
EOH
        }
    }
}
else {
    # topics home
    my $topic_class = $P{order} =~ m{\A description}xms? 'class=cur_sort': '';
    my $count_class = $P{order} =~ m{\A count}xms? 'class=cur_sort': '';
    print <<"EOH";
<span class=big>Topics</span>
<a class=left href=$cgi_bin_ml?cmd=add_topic accesskey='a'>Add Topics</a>
<a class=left href=$cgi_bin_ml?tab=messages accesskey='m'>Messages</a>
<a target=_blank class=left href=/ml/help.html accesskey='h'>Help</a>
$msg
Sort By
<a $topic_class href='$cgi_bin_ml?tab=topics&order=description+asc' accesskey='t'>Topic</a>
$space<a $count_class href='$cgi_bin_ml?tab=topics&order=count+desc,description+asc' accesskey='c'>Count</a>
<p>
EOH
    disp_topics(0,
                0, $P{order} || 'description asc', 1);
}
end_html();
