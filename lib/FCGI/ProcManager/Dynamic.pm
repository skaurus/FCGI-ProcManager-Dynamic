package FCGI::ProcManager::Dynamic;
use base FCGI::ProcManager;

# Copyright (c) 2012, Andrey Velikoredchanin.
# This library is free software released under the GNU Lesser General
# Public License, Version 3.  Please read the important licensing and
# disclaimer information included below.

# $Id: Dynamic.pm,v 0.2.1 2012/03/05 15:34:00 Andrey Velikoredchanin $

use strict;

use vars qw($VERSION);
BEGIN {
	$VERSION = '0.2.1';
}

use POSIX;
use Time::HiRes qw(usleep);
use IPC::SysV qw(IPC_PRIVATE IPC_CREAT IPC_NOWAIT IPC_RMID);

# Дополнительные параметры:
# 1. min_nproc - минимальное количество процессов
# 2. max_nproc - максимальное количество процессов
# 3. delta_nproc - на какое количество менять количество процессов при изменении
# 4. delta_time - минимальное количество секунд между последним увеличением или уменьшение к-ва процессов и последующим уменьшением
# 5. max_requests - максимальное количество запросов на один рабочий процесс

# Дополнительные функции:
# pm_loop
#	Параметры: нет
#	Возвращает: true если необходимо продолжить работу цикла рабочего процесса
# 	Пример использования (имеет смысл использовать только при установленном значении max_requests):
# 	while ($pm->pm_loop() && (my $query = new CGI::Fast)) {
#		$pm->pm_pre_dispatch();
#		...
#		$pm->pm_post_dispatch();
# 	};
# 	Это нужно что-бы можно было инициировать завершение рабочего процесса (при превышении количства обработанных запросов значения max_requests) дать процессу возможность сделать завершающие процедуры (отключение от БД и т.д.)

=head1 NAME

FCGI::ProcManager::Dynamic - extension of FCGI::ProcManager - functions for managing FastCGI applications. Here been add operations for dynamic managment of work processes.

=head1 SYNOPSIS

 # In Object-oriented style.
 use CGI::Fast;
 use FCGI::ProcManager::Dynamic;
 my $proc_manager = FCGI::ProcManager->new({
 	n_processes => 8,
 	min_nproc => 8,
 	max_nproc => 32,
 	delta_nproc => 4,
 	delta_time => 60,
 	max_requests => 300
 });
 $proc_manager->pm_manage();
 while ($proc_manager->pm_loop() && (my $cgi = CGI::Fast->new())) {
 	$proc_manager->pm_pre_dispatch();
 	# ... handle the request here ...
 	$proc_manager->pm_post_dispatch();
 }

=head1 DESCRIPTION

FCGI::ProcManager::Dynamic doin some for FCGI::ProcManager, but including extent parameters and functions for operation with count of work processes.

=head1 Addition options

=head2 min_nproc

Minimal count of work processes.

=head2 max_nproc

Maximal count of work processes.

=head2 delta_nproc

How match of work process need change for one time.

=head2 delta_time

When after last nproc changes possible decrement for count work processes.

=head2 max_requests

After work process processing this count of requests, work process finished and replacing for new work process.

=head1 Addition functions

=head2 pm_loop

This function need for correct finalize work process in after working loop code. For example, if you need disconnection from database or other actions before destroy working process. It recomend for using if you use parameter "max_requests".

=head1 BUGS

No known bugs, but this does not mean no bugs exist.

=head1 SEE ALSO

L<FCGI::ProcManager>
L<FCGI>

=head1 MAINTAINER

Andrey Velikoredchanin <andy@andyhost.ru>

=head1 AUTHOR

Andrey Velikoredchanin

=head1 COPYRIGHT

FCGI-ProcManager-Dynamic - A Perl FCGI Dynamic Process Manager
Copyright (c) 2012, Andrey Velikoredchanin.

This library is free software; you can redistribute it and/or
modify it under the terms of the GNU Lesser General Public
License as published by the Free Software Foundation; either
version 3 of the License, or (at your option) any later version.

BECAUSE THIS LIBRARY IS LICENSED FREE OF CHARGE, THIS LIBRARY IS
BEING PROVIDED "AS IS WITH ALL FAULTS," WITHOUT ANY WARRANTIES
OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING, WITHOUT
LIMITATION, ANY IMPLIED WARRANTIES OF TITLE, NONINFRINGEMENT,
MERCHANTABILITY OR FITNESS FOR A PARTICULAR PURPOSE, AND THE
ENTIRE RISK AS TO SATISFACTORY QUALITY, PERFORMANCE, ACCURACY,
AND EFFORT IS WITH THE YOU.  See the GNU Lesser General Public
License for more details.

You should have received a copy of the GNU Lesser General Public
License along with this library; if not, write to the Free Software
Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307  USA

=cut

sub pm_manage
{
	my $self = shift;

	$self->{USED_PROCS} = 0;

	if (!defined($self->{min_nproc})) { $self->{min_nproc} = $self->n_processes(); };
	if (!defined($self->{max_nproc})) { $self->{max_nproc} = 8; };
	if (!defined($self->{delta_nproc})) { $self->{delta_nproc} = 5; };
	if (!defined($self->{delta_time})) { $self->{delta_time} = 5; };

	$self->{_last_delta_time} = time();

	# Создает очередь сообщений
	$self->{ipcqueue} = msgget(IPC_PRIVATE, IPC_CREAT | 0666);
	print STDERR "\nОЧЕРЕДЬ: ", $self->{ipcqueue}, "\n";

	$self->{USEDPIDS} = {};

	$self->SUPER::pm_manage();
}

sub pm_wait
{
	my $self = shift;

	# wait for the next server to die.
	my $pid = 0;
	while ($pid >= 0)
	{
		$pid = waitpid(-1, WNOHANG);

		if ($pid > 0)
		{
			# notify when one of our servers have died.
			delete $self->{PIDS}->{$pid} and
			$self->pm_notify("worker (pid $pid) exited with status ".(($? eq '25600')? '100 (expired max request count)':$?));
		};

		# Читаем сообщения
		my $rcvd;
		my $delta_killed = $self->{delta_nproc};
		while (msgrcv($self->{ipcqueue}, $rcvd, 60, 0, IPC_NOWAIT))
		{
			my ($code, $cpid) = unpack("l! l!", $rcvd);
			if ($code eq '1')
			{
				$self->{USEDPIDS}->{$cpid} = 1;
			}
			elsif ($code eq '2')
			{
				delete($self->{USEDPIDS}->{$cpid});
			};
		};

		# Сверяем нет-ли в списке загруженных PID уже удаленных и считаем количество используемых
		$self->{USED_PROCS} = 0;
		foreach my $cpid (keys %{$self->{USEDPIDS}})
		{
			if (!defined($self->{PIDS}->{$cpid}))
			{
				delete($self->{USEDPIDS}->{$cpid});
			}
			else
			{
				$self->{USED_PROCS}++;
			};
		};

		# Балансировка процессов
		# Если загружены все процессы, добавляем
		if ($self->{USED_PROCS} >= $self->{n_processes})
		{
			# Добавляем процессы
			my $newnp = (($self->{n_processes} + $self->{delta_nproc}) < $self->{max_nproc})? ($self->{n_processes} + $self->{delta_nproc}):$self->{max_nproc};

			if ($newnp != $self->{n_processes})
			{
				$self->pm_notify("incrise workers count to $newnp");
				$self->SUPER::n_processes($newnp);
				$pid = -10;
				$self->{_last_delta_time} = time();
			};
		}
		elsif (($self->{USED_PROCS} < $self->{min_nproc}) && ((time() - $self->{_last_delta_time}) >= $self->{delta_time}))
		{
			# Если загруженных процессов меньше минимального количества, уменьшаем на delta_nproc до минимального значения

			my $newnp = (($self->{n_processes} - $self->{delta_nproc}) > $self->{min_nproc})? ($self->{n_processes} - $self->{delta_nproc}):$self->{min_nproc};

			if ($newnp != $self->{n_processes})
			{
				$self->pm_notify("decrise workers count to $newnp");

				# В цикле убиваем нужное количество незанятых процессов
				my $i = 0;
				foreach my $dpid (keys %{$self->{PIDS}})
				{
					# Убиваем только если процесс свободен
					if (!defined($self->{USEDPIDS}->{$dpid})) {
						$i++;
						if ($i <= ($self->{n_processes} - $newnp))
						{
							$self->pm_notify("kill worker $dpid");
							kill(SIGKILL, $dpid);
							delete($self->{PIDS}->{$dpid});
						}
						else
						{
							last;
						};
					};
				};
				$self->SUPER::n_processes($newnp);
				$self->{_last_delta_time} = time();
			};
		}
		elsif (keys(%{$self->{PIDS}}) < $self->{n_processes}) {
			# Если количество процессов меньше текущего - добавляем
			$self->pm_notify("incrise workers to ".$self->{n_processes});
			$self->{_last_delta_time} = time();
			$pid = -10;
		};

		if ($pid == 0)
		{
			usleep(100000);
		};
	};

	return $pid;
};

sub pm_pre_dispatch
{
	my $self = shift;
	$self->SUPER::pm_pre_dispatch();

	msgsnd($self->{ipcqueue}, pack("l! l!", 1, $$), 0);

	# Счетчик запросов
	if (!defined($self->{requestcount})) {
		$self->{requestcount} = 1;
	} else {
		$self->{requestcount}++;
	};
};

sub pm_post_dispatch
{
	my $self = shift;

	msgsnd($self->{ipcqueue}, pack("l! l!", 2, $$), 0);

	$self->SUPER::pm_post_dispatch();

	# Если определено максимальное количество запросов и оно превышено - выходим из чайлда
	if (defined($self->{max_requests}) && ($self->{max_requests} ne '') && ($self->{requestcount} >= $self->{max_requests})) {
		if ($self->{pm_loop_used}) {
			$self->{exit_flag} = 1;
		} else {
			# Если в цикле не используется pm_loop - выходим "жестко"
			exit;
		};
	};
};

sub pm_die
{
	my $self = shift;

	msgctl($self->{ipcqueue}, IPC_RMID, 0);

	$self->SUPER::pm_die();
};

sub pm_loop
{
	my $self = shift;

	$self->{pm_loop_used} = 1;

	return(!($self->{exit_flag}));
};

1;
