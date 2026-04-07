#
# Copyright 2024 Centreon (http://www.centreon.com/)
#
# Centreon is a full-fledged industry-strength solution that meets
# the needs in IT infrastructure and application monitoring for
# service performance.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

package cloud::azure::compute::avd::mode::connectionerrors;

use base qw(centreon::plugins::templates::counter);

use strict;
use warnings;

sub set_counters {
    my ($self, %options) = @_;

    $self->{maps_counters_type} = [
        { name => 'global', type => 0 }
    ];

    $self->{maps_counters}->{global} = [
        { label => 'connections-succeeded', nlabel => 'avd.connections.succeeded.count', set => {
                key_values      => [ { name => 'succeeded' } ],
                output_template => 'Succeeded: %d',
                perfdatas       => [ { template => '%d', min => 0 } ]
            }
        },
        { label => 'connections-failed', nlabel => 'avd.connections.failed.count', set => {
                key_values      => [ { name => 'failed' } ],
                output_template => 'Failed: %d',
                perfdatas       => [ { template => '%d', min => 0 } ]
            }
        },
        { label => 'connections-failure-rate', nlabel => 'avd.connections.failure.rate.percentage', set => {
                key_values      => [ { name => 'failure_rate' } ],
                output_template => 'Failure rate: %.1f%%',
                perfdatas       => [ { template => '%.1f', unit => '%', min => 0, max => 100 } ]
            }
        }
    ];
}

sub new {
    my ($class, %options) = @_;
    my $self = $class->SUPER::new(package => __PACKAGE__, %options, force_new_perfdata => 1);
    bless $self, $class;

    $options{options}->add_options(arguments => {
        'workspace-id:s'    => { name => 'workspace_id' },
        'filter-hostpool:s' => { name => 'filter_hostpool' },
        'filter-username:s' => { name => 'filter_username' },
        'timespan:s'        => { name => 'timespan', default => 'PT1H' }
    });

    return $self;
}

sub check_options {
    my ($self, %options) = @_;
    $self->SUPER::check_options(%options);

    if (!defined($self->{option_results}->{workspace_id}) || $self->{option_results}->{workspace_id} eq '') {
        $self->{output}->add_option_msg(short_msg => 'Need to specify --workspace-id option.');
        $self->{output}->option_exit();
    }
}

sub manage_selection {
    my ($self, %options) = @_;

    # Count completed connection attempts (succeeded vs failed) within the timespan.
    # WVDConnections rows with State == "Completed" represent finished connections;
    # their Outcome field holds "Success" or "Failure".
    my $query = 'WVDConnections'
        . ' | where State == "Completed"';

    if (defined($self->{option_results}->{filter_hostpool}) && $self->{option_results}->{filter_hostpool} ne '') {
        $query .= ' | where HostPoolName =~ "' . $self->{option_results}->{filter_hostpool} . '"';
    }
    if (defined($self->{option_results}->{filter_username}) && $self->{option_results}->{filter_username} ne '') {
        $query .= ' | where UserName contains "' . $self->{option_results}->{filter_username} . '"';
    }

    $query .= ' | summarize Succeeded=countif(Outcome == "Success"),'
            . ' Failed=countif(Outcome != "Success")';

    my $result = $options{custom}->azure_get_log_analytics(
        workspace_id => $self->{option_results}->{workspace_id},
        query        => $query,
        timespan     => $self->{option_results}->{timespan}
    );

    my ($succeeded, $failed) = (0, 0);

    foreach my $table (@{$result->{tables}}) {
        my %col_idx;
        my $i = 0;
        foreach my $col (@{$table->{columns}}) {
            $col_idx{$col->{name}} = $i++;
        }
        foreach my $row (@{$table->{rows}}) {
            $succeeded += $row->[$col_idx{Succeeded}] // 0 if exists $col_idx{Succeeded};
            $failed    += $row->[$col_idx{Failed}]    // 0 if exists $col_idx{Failed};
        }
    }

    my $total        = $succeeded + $failed;
    my $failure_rate = $total > 0 ? ($failed / $total * 100) : 0;

    $self->{global} = {
        succeeded    => $succeeded,
        failed       => $failed,
        failure_rate => $failure_rate
    };

    # Surface top error codes as long output for diagnostic convenience
    $self->_add_error_detail(%options);
}

sub _add_error_detail {
    my ($self, %options) = @_;

    return unless (defined($self->{option_results}->{filter_hostpool}) || 1);

    my $query = 'WVDErrors'
        . ' | where Source == "RDBroker" or Source == "RDGateway" or Source == "Client"';

    if (defined($self->{option_results}->{filter_hostpool}) && $self->{option_results}->{filter_hostpool} ne '') {
        $query .= ' | where HostPoolName =~ "' . $self->{option_results}->{filter_hostpool} . '"';
    }
    if (defined($self->{option_results}->{filter_username}) && $self->{option_results}->{filter_username} ne '') {
        $query .= ' | where UserName contains "' . $self->{option_results}->{filter_username} . '"';
    }

    $query .= ' | summarize Count=count() by CodeSymbolic, Source, ServiceError'
            . ' | order by Count desc'
            . ' | take 10';

    my $result = eval {
        $options{custom}->azure_get_log_analytics(
            workspace_id => $self->{option_results}->{workspace_id},
            query        => $query,
            timespan     => $self->{option_results}->{timespan}
        );
    };
    return if $@;

    foreach my $table (@{$result->{tables}}) {
        my %col_idx;
        my $i = 0;
        foreach my $col (@{$table->{columns}}) {
            $col_idx{$col->{name}} = $i++;
        }
        foreach my $row (@{$table->{rows}}) {
            my $code    = $row->[$col_idx{CodeSymbolic}]  // '(unknown)';
            my $source  = $row->[$col_idx{Source}]        // '';
            my $svc_err = $row->[$col_idx{ServiceError}]  // '';
            my $count   = $row->[$col_idx{Count}]         // 0;
            $self->{output}->output_add(
                long_msg => sprintf('  [%s] %s (source: %s, service_error: %s)', $count, $code, $source, $svc_err)
            );
        }
    }
}

1;

__END__

=head1 MODE

Check Azure Virtual Desktop connection errors by querying the C<WVDConnections>
and C<WVDErrors> Log Analytics tables.

Two counters are exposed:
- C<connections-succeeded>: connection attempts (C<State=Completed>, C<Outcome=Success>)
- C<connections-failed>: failed connection attempts (C<State=Completed>, C<Outcome!=Success>)
- C<connections-failure-rate>: percentage of failed attempts over the timespan

In verbose mode the top 10 error codes from C<WVDErrors> are added to the long
output with their count, source (C<RDBroker>, C<RDGateway>, C<Client>), and
whether the error is a service-side error.

Prerequisites: AVD diagnostics must be streamed to a Log Analytics workspace
(enable C<Connections> and C<Errors> in the host pool diagnostic settings).

Sample command:

perl centreon_plugins.pl --plugin=cloud::azure::compute::avd::plugin \
  --custommode=api --management-endpoint='https://api.loganalytics.io' \
  --mode=connection-errors \
  --subscription=XXXX --tenant=XXXX --client-id=XXXX --client-secret=XXXX \
  --workspace-id=XXXX --filter-hostpool='my-hostpool' \
  --timespan=PT1H \
  --warning-connections-failure-rate=5 \
  --critical-connections-failure-rate=20 --verbose

OK: Succeeded: 142, Failed: 3, Failure rate: 2.1%
  [2] UserNotAuthorized (source: RDBroker, service_error: True)
  [1] ConnectionFailedClientProtocolError (source: RDGateway, service_error: False)
| 'avd.connections.succeeded.count'=142;;;0; 'avd.connections.failed.count'=3;5;20;0;
  'avd.connections.failure.rate.percentage'=2.1%;5;20;0;100

=over 8

=item B<--workspace-id>

Log Analytics workspace ID (required).

=item B<--filter-hostpool>

Filter on a specific host pool name (case-insensitive).

=item B<--filter-username>

Filter on a specific user (partial match on UserName).

=item B<--timespan>

Lookback window for the query (default: C<PT1H>).
Accepted values: C<PT5M>, C<PT15M>, C<PT30M>, C<PT1H>, C<PT6H>, C<PT12H>, C<P1D>.

=item B<--warning-connections-succeeded>

Warning threshold for count of successful connections.

=item B<--critical-connections-succeeded>

Critical threshold for count of successful connections.

=item B<--warning-connections-failed>

Warning threshold for count of failed connections.

=item B<--critical-connections-failed>

Critical threshold for count of failed connections.

=item B<--warning-connections-failure-rate>

Warning threshold for the connection failure rate percentage.

=item B<--critical-connections-failure-rate>

Critical threshold for the connection failure rate percentage.

=back

=cut
