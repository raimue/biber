package Biber::Output::biblatexml;
use v5.16;
use strict;
use warnings;
use base 'Biber::Output::base';

use Biber;
use Biber::Config;
use Biber::Constants;
use Biber::Utils;
use List::AllUtils qw( :all );
use Encode;
use IO::File;
use Log::Log4perl qw( :no_extra_logdie_message );
use Text::Wrap;
use XML::Writer;
use Unicode::Normalize;
$Text::Wrap::columns = 80;
my $logger = Log::Log4perl::get_logger('main');

=encoding utf-8

=head1 NAME

Biber::Output::biblatexml - class for biblatexml output of tool mode

=cut


=head2 new

    Initialize a Biber::Output::biblatexml object

=cut

sub new {
  my $class = shift;
  my $obj = shift;
  my $self;
  if (defined($obj) and ref($obj) eq 'HASH') {
    $self = bless $obj, $class;
  }
  else {
    $self = bless {}, $class;
  }

  return $self;
}


=head2 set_output_target_file

    Set the output target file of a Biber::Output::biblatexml object
    A convenience around set_output_target so we can keep track of the
    filename

=cut

sub set_output_target_file {
  my $self = shift;
  my $toolfile = shift;
  # Make the right casing function and store it

  $self->{output_target_file} = $toolfile;
  my $bltxml = 'http://biblatex-biber.sourceforge.net/biblatexml';
  $self->{xml_prefix} = $bltxml;

  my $xml = XML::Writer->new(OUTPUT      => IO::File->new($toolfile, '>:encoding(UTF-8)'),
                             DATA_MODE   => 1,
                             DATA_INDENT => Biber::Config->getoption('tool_indent'),
                             NAMESPACES  => 1,
                             PREFIX_MAP  => {$bltxml => 'bltx'});
  $xml->xmlDecl("UTF-8");
  $xml->comment("Auto-generated by Biber::Output::biblatexml");
  $xml->startTag([$self->{xml_prefix}, 'entries']);
  $self->set_output_target($xml);
}

=head2 set_output_entry

  Set the output for an entry

=cut

sub set_output_entry {
  my $self = shift;
  my $be = shift; # Biber::Entry object
  my $bee = $be->get_field('entrytype');
  my $section = shift; # Section object the entry occurs in
  my $dm = shift; # Data Model object
  my $secnum = $section->number;
  my $key = $be->get_field('citekey');
  my $xml = $self->{output_target};
  my $xml_prefix = $self->{xml_prefix};

  $xml->startTag([$xml_prefix, 'entry'], id => NFC($key), entrytype => NFC($bee));

  # If IDS, CROSSREF and XDATA have been resolved, don't output them
  # We can't use the usual skipout test for fields not to be output
  # as this only refers to .bbl output and not to biblatexml output since this
  # latter is not really a "processed" output, it is supposed to be something
  # which could be again used as input and so we don't want to resolve/skip
  # fields like DATE etc.
  unless (Biber::Config->getoption('tool_resolve')) {
    #      next if lc($f) ~~ ['ids', 'xdata', 'crossref'];
    # TODO - ALIASES
    # TODO - XDATA, CROSSREF
  }

  # Output name fields
  foreach my $namefield (@{$dm->get_fields_of_type('list', 'name')}) {
    next unless my $nf = $be->get_field($namefield);

    # Did we have "and others" in the data?
    if ( $nf->get_morenames ) {
      $xml->startTag([$xml_prefix, $namefield], morenames => 1);
    }
    else {
      $xml->startTag([$xml_prefix, $namefield]);
    }

    # Name loop
    foreach my $n (@{$nf->names}) {
      $n->name_to_biblatexml($xml, $self);
    }

    $xml->endTag(); # Names
  }

  # Output list fields
  foreach my $listfield (@{$dm->get_fields_of_fieldtype('list')}) {
    next if $dm->field_is_datatype('name', $listfield); # name is a special list
    next if $listfield eq 'ids'; # IDS is a special list
    next if $listfield eq 'xdata'; # XDATA is a special list
    if (my $lf = $be->get_field($listfield)) {
      # Did we have a "more" list?
      if (lc($lf->[-1]) eq Biber::Config->getoption('others_string') ) {
        $xml->startTag([$xml_prefix, $listfield], morelist => 1);
        pop @$lf; # remove the last element in the array
      }
      else {
        $xml->startTag([$xml_prefix, $listfield]);
      }

      # List loop
      foreach my $f (@$lf) {
        $xml->dataElement([$xml_prefix, 'item'], NFC($f));
      }
      $xml->endTag();# List
    }
  }

  # Standard fields
  foreach my $field (sort @{$dm->get_fields_of_type('field', 'entrykey')},
                      @{$dm->get_fields_of_type('field', 'key')},
                      @{$dm->get_fields_of_type('field', 'literal')},
                      @{$dm->get_fields_of_type('field', 'code')},
                      @{$dm->get_fields_of_datatype('integer')},
                      @{$dm->get_fields_of_datatype('verbatim')},
                      @{$dm->get_fields_of_datatype('uri')}) {
    if ( ($dm->field_is_nullok($field) and
          $be->field_exists($field)) or
         $be->get_field($field) ) {
      my $f = $be->get_field($field);

      # date related fields need special handling
      next if $field =~ m/(?:year|month|day)\z/xms;

      $xml->dataElement([$xml_prefix, $field], NFC($f));
    }
  }

  # Range fields
  foreach my $rfield (@{$dm->get_fields_of_datatype('range')}) {
    if ( my $rf = $be->get_field($rfield) ) {
      # range fields are an array ref of two-element array refs [range_start, range_end]
      # range_end can be be empty for open-ended range or undef
      $xml->startTag([$xml_prefix, $rfield]);
      $xml->startTag([$xml_prefix, 'list']);

      foreach my $f (@$rf) {
        $xml->startTag([$xml_prefix, 'item']);
        if (defined($f->[1])) {
          $xml->dataElement([$xml_prefix, 'start'], NFC($f->[0]));
          $xml->dataElement([$xml_prefix, 'end'], NFC($f->[1]));
        }
        else {
          $xml->characters(NFC($f->[0]));
        }
        $xml->endTag();# item
      }
      $xml->endTag();# list
      $xml->endTag();# range
    }
  }

  # Date fields
  foreach my $dfield (@{$dm->get_fields_of_type('field', 'date')}) {
    if ( my $df = $be->get_field($dfield) ) {
      if (my ($byear, $bmonth, $bday, $r, $eyear, $emonth, $eday) = parse_date($df)) {
        if ($dfield =~ m/\A(.+)date\z/xms;) {
          $xml->startTag([$xml_prefix, 'date'], datetype => $1);
        }
        else {
          $xml->startTag([$xml_prefix, 'date']);
        }

        $xml->dataElement([$xml_prefix, 'start'], NFC());
        $xml->dataElement([$xml_prefix, 'end'], NFC());

    }
      $xml->endTag();# date
  }

  $xml->endTag();

  # Create an index by keyname for easy retrieval
#  $self->{output_data}{ENTRIES}{$secnum}{index}{$key} = \$acc;

  return;
}


=head2 output

    Tool output method

=cut

sub output {
  my $self = shift;
  my $data = $self->{output_data};
  my $xml = $self->{output_target};
  my $target_string = "Target"; # Default
  if ($self->{output_target_file}) {
    $target_string = $self->{output_target_file};
  }

  # for debugging mainly
  # unless ($target) {
  #   $target = new IO::File '>-';
  # }

  $logger->debug('Preparing final output using class ' . __PACKAGE__ . '...');
  $logger->debug("Writing entries in tool mode");

  # There is only a (pseudo) section "0" in tool mode
  # foreach my $key ($Biber::MASTER->sortlists->get_list(0, 'entry', 'tool')->get_keys) {
  #   out($xml, ${$data->{ENTRIES}{0}{index}{$key}});
  # }

  $xml->endTag();
  $xml->end();

  $logger->info("Output to $target_string");
  return;
}

=head2 create_output_section

    Create the output from the sections data and push it into the
    output object.

=cut

sub create_output_section {
  my $self = shift;
  my $secnum = $Biber::MASTER->get_current_section;
  my $section = $Biber::MASTER->sections->get_section($secnum);


  # We rely on the order of this array for the order of the .bbl
  foreach my $k ($section->get_citekeys) {
    # Regular entry
    my $be = $section->bibentry($k) or biber_error("Cannot find entry with key '$k' to output");
    $self->set_output_entry($be, $section, Biber::Config->get_dm);
  }

  # Make sure the output object knows about the output section
  $self->set_output_section($secnum, $section);

  return;
}


1;

__END__

=head1 AUTHORS

François Charette, C<< <firmicus at ankabut.net> >>
Philip Kime C<< <philip at kime.org.uk> >>

=head1 BUGS

Please report any bugs or feature requests on our sourceforge tracker at
L<https://sourceforge.net/tracker2/?func=browse&group_id=228270>.

=head1 COPYRIGHT & LICENSE

Copyright 2009-2013 François Charette and Philip Kime, all rights reserved.

This module is free software.  You can redistribute it and/or
modify it under the terms of the Artistic License 2.0.

This program is distributed in the hope that it will be useful,
but without any warranty; without even the implied warranty of
merchantability or fitness for a particular purpose.

=cut