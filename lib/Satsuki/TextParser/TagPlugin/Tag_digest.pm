use strict;
#------------------------------------------------------------------------------
# メッセージダイジェストプラグイン
#                                                   (C)2013 nabe / nabe@abk.nu
#------------------------------------------------------------------------------
package Satsuki::TextParser::TagPlugin::Tag_digest;
use Fcntl;
###############################################################################
# ■基本処理
###############################################################################
# [md5:id:dir:file]
#------------------------------------------------------------------------------
# ●コンストラクタ
#------------------------------------------------------------------------------
sub new {
	my $class = shift;	# 読み捨て
	my $ROBJ  = shift;	# 読み捨て

	my $tags  = shift;

	#---begin_plugin_info
	$tags->{'md5'}   ->{data} = \&digest;
	$tags->{'sha'}   ->{data} = \&digest;
	$tags->{'sha1'}  ->{data} = \&digest;
	$tags->{'sha224'}->{data} = \&digest;
	$tags->{'sha256'}->{data} = \&digest;
	$tags->{'sha384'}->{data} = \&digest;
	$tags->{'sha512'}->{data} = \&digest;

	$tags->{'file:md5'}   ->{data} = \&file_digest;
	$tags->{'file:sha'}   ->{data} = \&file_digest;
	$tags->{'file:sha1'}  ->{data} = \&file_digest;
	$tags->{'file:sha224'}->{data} = \&file_digest;
	$tags->{'file:sha256'}->{data} = \&file_digest;
	$tags->{'file:sha384'}->{data} = \&file_digest;
	$tags->{'file:sha512'}->{data} = \&file_digest;
	#---end

	return ;
}
###############################################################################
# ■タグ処理ルーチン
###############################################################################
#------------------------------------------------------------------------------
# ●文字列のダイジェスト記法
#------------------------------------------------------------------------------
sub digest {
	my ($parser_obj, $tag, $cmd, $ary) = @_;
	my $tags = $parser_obj->{tags};
	my $ROBJ = $parser_obj->{ROBJ};
	my $replace_data = $parser_obj->{replace_data};

	# type=cmd
	my $digest_type = $cmd;
	my $str = join(':', @$ary);

	# digestの生成
	my $digest;
	my $obj = &load_digest_obj( $digest_type );
	if (ref($obj)) {
		$obj->add($str);
		$digest = $obj->hexdigest;
	} else { # エラーのとき
		$digest = $obj;
	}

	# Digestを返す
	$ROBJ->tag_escape($str);
	return "<span class=\"digest\" title=\"($digest_type) $str\">$digest</span>";
}

#------------------------------------------------------------------------------
# ●ファイルのダイジェスト記法
#------------------------------------------------------------------------------
sub file_digest {
	my ($parser_obj, $tag, $cmd, $ary) = @_;
	my $tags = $parser_obj->{tags};
	my $ROBJ = $parser_obj->{ROBJ};
	my $replace_data = $parser_obj->{replace_data};

	# file tag のロード
	my ($urltag, $digest_type) = split(':', $cmd);
	$urltag = $tags->{$urltag};

	# file url構成
	my $file = $urltag->{data};
	my $argc = $urltag->{argc};
	my @argv = splice(@$ary, 0, $argc);
	unshift(@argv, '(fileext-dummy)');
	my @argv2 = @argv;
	$ROBJ->tag_escape(@argv2);
	my $name = $argv2[$#argv2];
	unshift(@argv,  $ROBJ->{Basepath});
	$file =~ s/\$(\d)/$argv[$1]/g;			# 文字コード変換後
	$file =~ s/\$\{(\w+)\}/$replace_data->{$1}/g;	# 任意データ置換
	if ($file =~ /\$\$/) {	# 全引数置換
		shift(@argv);
		my $str = join(':', @argv);
		$file =~ s/\$\$/$str/g;
	}

	# パスを安全チェック
	$ROBJ->clean_path( $file );
	$file = $ROBJ->get_filepath( $file );

	# digestの生成
	my $digest;
	if ( sysopen(my $fh, $file, O_RDONLY) ) {
		my $obj = &load_digest_obj( $digest_type );
		if (ref($obj)) {
			$obj->addfile($fh);
			$digest = $obj->hexdigest;

		} else { # エラーのとき
			$digest = $obj;
		}
	  	close($fh)
	} else {
		$digest="(file not found)";
	}

	# Digestを返す
	$ROBJ->tag_escape($file);
	return "<span class=\"digest\" title=\"($digest_type) $file\">$digest</span>";
}

###############################################################################
# ■サブルーチン
###############################################################################
sub load_digest_obj {
	my $type = shift;
	my $obj;
	my $lib;
  eval {
	if ($type eq 'md5') {
		$lib = 'Digest::MD5';
		require Digest::MD5;
		$obj = Digest::MD5->new;
	} elsif ($type eq 'sha'    || $type eq 'sha1'   || $type eq 'sha224'
	      || $type eq 'sha256' || $type eq 'sha384' || $type eq 'sha512') {
		my $algo=256;	# default
		if ($type =~ /^sha(\d+)/) { $algo=$1; }
		$lib = 'Digest::SHA or Digest::SHA::PurePerl';
		eval {
			require Digest::SHA;
			$obj = Digest::SHA->new($algo);
		};
		if ($@) {
			require Digest::SHA::PurePerl;
			$obj = Digest::SHA::PurePerl->new($algo);
		}
	} else {
		$obj="('$type' unknown digest type)";
	}
  };
	# エラーあり
  	if ($@) { return "($lib not found)"; }
 	return $obj;
}

1;
