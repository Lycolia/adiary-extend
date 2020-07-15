use strict;
#------------------------------------------------------------------------------
# データベースプラグイン for PostgreSQL
#						(C)2006-2020 nabe@abk
#------------------------------------------------------------------------------
package Satsuki::DB_pg;
use Satsuki::AutoLoader;
use Satsuki::DB_share;
use DBI ();
our $VERSION = '1.21';
#------------------------------------------------------------------------------
# データベースの接続属性 (DBI)
my %DB_attr = (AutoCommit => 1, RaiseError => 0, PrintError => 0, PrintWarn => 0, pg_enable_utf8 => 0);
#------------------------------------------------------------------------------
###############################################################################
# ■基本処理
###############################################################################
#------------------------------------------------------------------------------
# ●【コンストラクタ】
#------------------------------------------------------------------------------
sub new {
	my $class = shift;
	my ($ROBJ, $database, $username, $password, $self) = @_;
	$self ||= {};
	bless($self, $class);
	$self->{ROBJ} = $ROBJ;	# root object save

	# 初期設定
	$self->{_RDBMS} = 'PostgreSQL';
	$self->{db_id}  = "pg.$database.";
	$self->{exist_tables_cache} = {};

	# 接続
	my $connect = $self->{Pool} ? 'connect_cached' : 'connect';
	my $dbh = DBI->$connect("DBI:Pg:$database", $username, $password, \%DB_attr);
	if (!$dbh) { $self->error('Connection faild'); return ; }
	$self->{dbh} = $dbh;

	# 初期設定
	$dbh->{pg_expand_array}=0;

	# UTF8判定 // DBD::Pg bug対策
	my $ver = $DBD::Pg::VERSION;
	if ($ver =~ /^3\.(.*)/) {
		$ver = $1;
		if (3.0 <= $ver && $ver < 6.0) {
			# DBD Ver 3.3.0 to 3.5.3
			require Encode;
			$self->{PATCH_for_UTF8_flag} = 1;
		}
	}
	return $self;
}
#------------------------------------------------------------------------------
# ●デストラクタ代わり
#------------------------------------------------------------------------------
sub Finish {
	my $self = shift;
	if ($self->{begin}) { $self->rollback(); }
}
#------------------------------------------------------------------------------
# ●再接続
#------------------------------------------------------------------------------
sub reconnect {
	my $self = shift;
	my $force= shift;
	my $dbh  = $self->{dbh};
	if (!$force && $dbh->ping()) {
		return;
	}
	$self->{dbh} = $dbh->clone();
}

###############################################################################
# ■テーブルの操作
###############################################################################
#------------------------------------------------------------------------------
# ●テーブルの存在確認
#------------------------------------------------------------------------------
sub find_table {
	my ($self, $table) = @_;
	my $ROBJ = $self->{ROBJ};
	$table =~ s/\W//g;

	# キャッシュの確認
	my $cache    = $self->{exist_tables_cache};
	my $cache_id = $self->{db_id} . $table;
	if ($cache->{$cache_id}) { return $cache->{$cache_id}; }

	# テーブルからの情報取得
	my $dbh = $self->{dbh};
	my $sql = "SELECT tablename FROM pg_tables WHERE tablename=? LIMIT 1";
	my $sth = $dbh->prepare_cached($sql);
	$self->debug($sql);	# debug-safe
	$sth && $sth->execute($table);

	if (!$sth || !$sth->rows || $dbh->err) { return 0; }	# error
	return ($cache->{$cache_id} = 1);	# found
}

###############################################################################
# ■データの検索
###############################################################################
sub select {
	my ($self, $table, $h) = @_;
	my $dbh  = $self->{dbh};
	my $ROBJ = $self->{ROBJ};
	$table =~ s/\W//g;

	my $require_hits = wantarray;

	#---------------------------------------------
	# マッチング条件の処理
	#---------------------------------------------
	my ($where, $ary) = $self->generate_select_where($h);

	#---------------------------------------------
	# SQLを構成
	#---------------------------------------------
	# 取得するカラム
	my $cols = "*";
	my $select_cols = (!exists$h->{cols} || ref($h->{cols})) ? $h->{cols} : [ $h->{cols} ];
	if (ref($select_cols)) {
		foreach(@$select_cols) { $_ =~ s/\W//g; }
		$cols = join(',', @$select_cols);
	}
	# SQL
	my $sql = "SELECT $cols FROM $table$where";

	#---------------------------------------------
	# ソート処理
	#---------------------------------------------
	$sql .= $self->generate_order_by($h);

	#---------------------------------------------
	# limit and offset
	#---------------------------------------------
	my $offset = int($h->{offset});
	my $limit;
	if ($h->{limit} ne '') { $limit = int($h->{limit}); }
	if ($offset > 0)  { $sql .= ' OFFSET ' . $offset; }
	if ($limit ne '') { $sql .= ' LIMIT '  . $limit;  }

	#---------------------------------------------
	# Do SQL
	#---------------------------------------------
	my $sth = $dbh->prepare_cached($sql);
	$self->debug($sql);	# debug-safe
	$sth && $sth->execute(@$ary);
	if (!$sth || $dbh->err) {
		$self->error($sql);
		$self->error($dbh->errstr);
		return [];
	}

	my $ret = $sth->fetchall_arrayref({});

	if (!$require_hits) { return $ret; }

	#---------------------------------------------
	# 該当件数の取得
	#---------------------------------------------
	my $hits = $#$ret+1;
	if ($limit ne '' && $limit <= $hits) {
		my $sql = "SELECT count(*) FROM $table$where";
		my $sth = $dbh->prepare_cached($sql);
		$self->debug($sql);	# debug-safe
		$sth && $sth->execute(@$ary);
		if (!$sth || $dbh->err) {
			$self->error($sql);
			$self->error($dbh->errstr);
			return [];
		}
		$hits = $sth->fetchrow_array;
		$sth->finish();
	}
	return ($ret,$hits);
}


###############################################################################
# ■サブルーチン
###############################################################################
#------------------------------------------------------------------------------
# ●whereの生成（外部から参照される）
#------------------------------------------------------------------------------
sub generate_select_where {
	my ($self, $h) = @_;

	my $where;
	my @ary;
	foreach(sort(keys(%{ $h->{match} }))) {
		my $k = $_;
		my $v = $h->{match}->{$_};

		$k =~ s/\W//g;
		if ($v eq '') {
			$where .= " AND $k IS NULL";
			next;
		}
		if (ref($v) ne 'ARRAY') {
			$where .= " AND $k=?";
			push(@ary, $v);
			next;
		}
		# 値が配列のとき
		my $w = '?,' x ($#$v+1);
		chop($w);
		if ($w eq '') { 
			$where .= " AND false";
			next;
		}
		$where .= " AND $k in ($w)";
		push(@ary, @$v);
	}
	foreach(sort(keys(%{ $h->{not_match} }))) {
		my $k = $_;
		my $v = $h->{not_match}->{$_};

		$k =~ s/\W//g;
		if ($v eq '') {
			$where .= " AND $k IS NOT NULL";
			next;
		}
		if (ref($v) ne 'ARRAY') {
			$where .= " AND $k!=?";
			push(@ary, $v);
			next;
		}
		# 値が配列のとき
		my $w = '?,' x ($#$v+1);
		chop($w);
		if ($w eq '') { next; }
		$where .= " AND $k not in ($w)";
		push(@ary, @$v);
	}
	foreach(sort(keys(%{ $h->{min} }))) {
		my $k = $_;
		$k =~ s/\W//g;
		$where .= " AND $k>=?";
		push(@ary, $h->{min}->{$_});
	}
	foreach(sort(keys(%{ $h->{max} }))) {
		my $k = $_;
		$k =~ s/\W//g;
		$where .= " AND $k<=?";
		push(@ary, $h->{max}->{$_});
	}
	foreach(sort(keys(%{ $h->{gt} }))) {
		my $k = $_;
		$k =~ s/\W//g;
		$where .= " AND $k>?";
		push(@ary, $h->{gt}->{$_});
	}
	foreach(sort(keys(%{ $h->{lt} }))) {
		my $k = $_;
		$k =~ s/\W//g;
		$where .= " AND $k<?";
		push(@ary, $h->{lt}->{$_});
	}
	foreach(sort(keys(%{ $h->{flag} }))) {
		my $k = $_;
		$k =~ s/\W//g;
		$where .= " AND " . ($h->{flag}->{$_} ? '' : 'NOT ') . $k;
	}
	foreach(@{ $h->{is_null} }) {
		$_ =~ s/\W//g;
		$where .= " AND $_ IS NULL";
	}
	foreach(@{ $h->{not_null} }) {
		$_ =~ s/\W//g;
		$where .= " AND $_ IS NOT NULL";
	}
	if ($h->{search_cols} || $h->{search_match}) {
		my $words = $h->{search_words};
		foreach my $word (@$words) {
			my $w = $word;
			$w =~ s/([\\%_])/\\$1/g;
			my @x;
			foreach (@{ $h->{search_match} || [] }) {
				push(@x, "$_ ILIKE ?");
				push(@ary, $w);
			}
			$w = "%$w%";
			foreach (@{ $h->{search_cols}  || [] }) {
				push(@x, "$_ ILIKE ?");
				push(@ary, $w);
			}
			$where .= " AND (" . join(' OR ', @x) . ")";
		}
	}
	if ($h->{RDB_where} ne '') { # RDBMS専用、where直指定
		my $add = $h->{RDB_where};
		$add =~ s/[\\;\x80-\xff]//g;
		my $c = ($add =~ tr/'/'/);	# 'の数を数える
		if ($c & 1)	{		# 奇数ならすべて除去
			$add =~ s/'//g;
		}
		$where .= ' AND '.$add;
		if ($h->{RDB_values}) {
			push(@ary, @{ $h->{RDB_values} });
		}
	}

	if ($where) { $where = ' WHERE' . substr($where, 4); }

	$self->utf8_on(\@ary);

	return ($where, \@ary);
}

#------------------------------------------------------------------------------
# ●ORDER BYの生成
#------------------------------------------------------------------------------
sub generate_order_by {
	my ($self, $h) = @_;
	my $sort = ref($h->{sort}    ) ? $h->{sort}     : [ $h->{sort}     ];
	my $rev  = ref($h->{sort_rev}) ? $h->{sort_rev} : [ $h->{sort_rev} ];
	my $sql='';
	if ($h->{RDB_order} ne '') {	# RDBMS専用、order直指定
		$sql .= ' ' . $h->{RDB_order} . ',';
	}
	foreach(0..$#$sort) {
		my $col = $sort->[$_];
		my $rev = $rev->[$_] || ord($col) == 0x2d;	# '-colname'
		$col =~ s/\W//g;
		if ($col eq '') { next; }
		$sql .= ' ' . $col . ($rev ? ' DESC,' : ',');
	}
	chop($sql);
	if ($sql) {
		$sql = ' ORDER BY' . $sql;
	}
	return $sql
}

#------------------------------------------------------------------------------
# ●エラーフック
#------------------------------------------------------------------------------
# $self->error in DB_share.pm から呼ばれる
sub error_hook {
	my $self = shift;
	if ($self->{begin}) {
		$self->{begin}=-1;	# error
	}
}

#------------------------------------------------------------------------------
# ●utf8フラグをつける
#------------------------------------------------------------------------------
sub utf8_on {
	my $self = shift;
	if (!$self->{PATCH_for_UTF8_flag}) { return; }

	my $ary = shift;
	foreach(@$ary) {
		Encode::_utf8_on($_);
	}
}

###############################################################################
# ●タイマーの仕込み
###############################################################################
&embed_timer_wrapper(__PACKAGE__);

1;
