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

package cloud::azure::compute::avd::mode::sessions;

use base qw(centreon::plugins::templates::counter);

use strict;
use warnings;

sub prefix_pool_output {
    my ($self, %options) = @_;

    return "Host pool '" . $options{instance_value}->{display} . "' ";
}

sub set_counters {
    my ($self, %options) = @_;

    $self->{maps_counters_type} = [
        { name => 'pools', type => 1, cb_prefix_output => 'prefix_pool_output',
          message_multiple => 'All host pools are ok' }
    ];

    $self->{maps_counters}->{pools} = [
        { label => 'sessions-active', nlabel => 'avd.sessions.active.count', set => {
                key_values      => [ { name => 'active' }, { name => 'display' } ],
                output_template => 'Active sessions: %d',
                perfdatas       => [
                    { template => '%d', min => 0, label_extra_instance => 1, instance_use => 'display' }
                ]
            }
        },
        { label => 'sessions-disconnected', nlabel => 'avd.sessions.disconnected.count', set => {
                key_values      => [ { name => 'disconnected' }, { name => 'display' } ],
                output_template => 'Disconnected sessions: %d',
                perfdatas       => [
                    { template => '%d', min => 0, label_extra_instance => 1, instance_use => 'display' }
                ]
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
        'timespan:s'        => { name => 'timespan', default => 'PT15M' }
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

    # Count currently active/disconnected sessions per host pool.
    # WVDConnections rows with State == "Connected" represent active sessions.
    # Rows with State == "Completed" and no subsequent "Connected" for the same
    # CorrelationId represent completed (disconnected) sessions.
    # The simplest reliable approach: summarize the most recent State per
    # session (CorrelationId) and count statuses.
    my $query = 'WVDConnections'
        . ' | summarize arg_max(TimeGenerated, State) by CorrelationId, HostPoolName';

    if (defined($self->{option_results}->{filter_hostpool}) && $self->{option_results}->{filter_hostpool} ne '') {
        $query .= ' | where HostPoolName =~ "' . $self->{option_results}->{filter_hostpool} . '"';
    }

    $query .= ' | summarize'
            . ' Active=countif(State == "Connected"),'
            . ' Disconnected=countif(State == "Completed")'
            . ' by HostPoolName';

    my $result = $options{custom}->azure_get_log_analytics(
        workspace_id => $self->{option_results}->{workspace_id},
        query        => $query,
        timespan     => $self->{option_results}->{timespan}
    );

    $self->{pools} = {};

    foreach my $table (@{$result->{tables}}) {
        my %col_idx;
        my $i = 0;
        foreach my $col (@{$table->{columns}}) {
            $col_idx{$col->{name}} = $i++;
        }

        foreach my $row (@{$table->{rows}}) {
            my $pool_name    = $row->[$col_idx{HostPoolName}]  // '(unknown)';
            my $active       = $row->[$col_idx{Active}]        // 0;
            my $disconnected = $row->[$col_idx{Disconnected}]  // 0;

            $self->{pools}->{$pool_name} = {
                display      => $pool_name,
                active       => $active,
                disconnected => $disconnected
            };
        }
    }

    if (scalar(keys %{$self->{pools}}) <= 0) {
        $self->{output}->add_option_msg(short_msg =>
            'No session data found. Check --workspace-id and --timespan, '
            . 'and ensure WVDConnections diagnostics are enabled.'
        );
        $self->{output}->option_exit();
    }
}

1;

__END__

=head1 MODE

Check Azure Virtual Desktop active and disconnected session counts by querying
the C<WVDConnections> Log Analytics table.

For each host pool the mode reports:
- C<sessions-active>: sessions whose most recent state is C<Connected>
- C<sessions-disconnected>: sessions whose most recent state is C<Completed>
  (i.e. finalized / disconnected within the timespan)

Results are broken down per host pool. Use C<--filter-hostpool> to restrict to
a single pool.

Prerequisites: AVD diagnostics must be streamed to a Log Analytics workspace
(enable C<Connections> in the host pool diagnostic settings).

Sample command:

perl centreon_plugins.pl --plugin=cloud::azure::compute::avd::plugin \
  --custommode=api --management-endpoint='https://api.loganalytics.io' \
  --mode=sessions \
  --subscription=XXXX --tenant=XXXX --client-id=XXXX --client-secret=XXXX \
  --workspace-id=XXXX \
  --timespan=PT15M \
  --warning-sessions-active=200 --critical-sessions-active=300 --verbose

OK: All host pools are ok
  Host pool 'pool-prod-01' Active sessions: 87, Disconnected sessions: 12
  Host pool 'pool-dev-01'  Active sessions: 5,  Disconnected sessions: 1
| 'pool-prod-01#avd.sessions.active.count'=87;200;300;0;
  'pool-prod-01#avd.sessions.disconnected.count'=12;;;0;

=over 8

=item B<--workspace-id>

Log Analytics workspace ID (required).

=item B<--filter-hostpool>

Filter on a specific host pool name (case-insensitive). When omitted, all
host pools visible in the workspace are returned.

=item B<--timespan>

Lookback window for the query (default: C<PT15M>).
Accepted values: C<PT5M>, C<PT15M>, C<PT30M>, C<PT1H>, C<PT6H>, C<PT12H>, C<P1D>.

=item B<--warning-sessions-active>

Warning threshold for the number of active sessions (per host pool).

=item B<--critical-sessions-active>

Critical threshold for the number of active sessions (per host pool).

=item B<--warning-sessions-disconnected>

Warning threshold for the number of disconnected sessions (per host pool).

=item B<--critical-sessions-disconnected>

Critical threshold for the number of disconnected sessions (per host pool).

=back

=cut
