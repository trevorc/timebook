#!/usr/bin/python
#
# timebook 0.2 Copyright (c) 2008 Trevor Caira
# 
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
# 
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
# IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
# CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
# TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
# SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

__author__ = 'Trevor Caira <trevor@caira.com>'
__version__ = (0, 2, 0)

import cPickle as pickle
from ConfigParser import SafeConfigParser
from datetime import datetime, timedelta
from functools import wraps
from optparse import OptionParser
import os
import time

confdir = os.path.expanduser(os.path.join('~', '.config', 'timebook'))
DEFAULTS = {'config': os.path.join(confdir, 'timebook.ini'),
            'timebook': os.path.join(confdir, 'sheets.dat')}

class AmbiguousLookup(ValueError): pass

class ConfigParser(SafeConfigParser):
    def __getitem__(self, name):
        return dict(self.items(name))

class NoMatch(ValueError): pass

commands = {}
aliases = {}
def command(desc, cmd_aliases=()):
    def decorator(func):
        func_name = func.func_code.co_name
        commands[func_name] = desc
        for alias in cmd_aliases:
            aliases[alias] = func
        def decorated(self, args, **kwargs):
            args, kwargs = self.pre_hook(func_name)(self, args, kwargs)
            res = func(self, args, **kwargs)
            return self.post_hook(func_name)(self, res)
        return wraps(func)(decorated)
    return decorator

class Entry(object):
    def __init__(self, start, end, desc, extra=None):
        self.start, self.end, self.desc, self.extra = \
            start, end, desc, extra

    def __iter__(self):
        tup = (self.start, self.end, self.desc) + ((self.extra,)
            if self.extra is not None else ())
        return iter(tup)

    def __repr__(self):
        desc = '' if self.desc is None else ' %r' % self.desc
        return '<Entry%s>' % (desc)

    def serialize(self):
        return tuple(self)

class Timesheet(list):
    def __init__(self, init=()):
        super(Timesheet, self).__init__([Entry(*e) for e in init])

    def __getslice__(self, start, end):
        return type(self)(super(Timesheet, self).__getslice__(start, end))

    @property
    def active(self):
        return self and self[-1].end is None

    @property
    def running(self):
        if self.active:
            diff = int(time.time()) - self[-1].start
            return str(timedelta(seconds=diff))
        raise ValueError('sheet not active')

    @property
    def total(self):
        return sum([e.end - e.start for e in self
                    if e.end is not None]) + (int(time.time()) -
                                              self[-1].start
                                              if self.active else 0)

    @property
    def today_total(self):
        from bisect import bisect

        now = datetime.now()
        midnight = int(time.mktime(datetime(now.year, now.month,
                                            now.day).timetuple()))
        first_item_today = bisect([r.start for r in self], midnight)
        today = self[first_item_today:]
        return today.total

    def serialize(self):
        return [entry.serialize() for entry in self]

class Timebook(dict):
    def __init__(self, options, config):
        self.options = options
        self.config = config
        unpickled = self.unpickle(options.timebook)
        self._load(unpickled)

    def _load(self, unpickled):
        self.clear()
        if unpickled is None:
            self._current = 'default'
            self.update(default=Timesheet())
        else:
            self._current = unpickled['current']
            self.update([(name, Timesheet(s)) for name, s
                         in unpickled['sheets'].iteritems()])

    def pre_hook(self, func_name):
        if self.config.has_section('hooks'):
            hook = self.config['hooks'].get(func_name)
            if hook is not None:
                mod = __import__(hook, {}, {}, [''])
                if hasattr(mod, 'pre'):
                    return mod.pre
        return lambda self, args, kwargs: (args, kwargs)

    def post_hook(self, func_name):
        if self.config.has_section('hooks'):
            hook = self.config['hooks'].get(func_name)
            if hook is not None:
                mod = __import__(hook, {}, {}, [''])
                if hasattr(mod, 'post'):
                    return mod.post
        return lambda self, res: res

    def unpickle(self, filename):
        try:
            f = file(filename)
        except IOError, e:
            if e.errno != 2:
                raise
            return None
        try:
            return pickle.loads(f.read())
        except EOFError:
            return None
        finally:
            f.close()

    def pformat(self):
        f = file(self.options.timebook)
        try:
            from pprint import PrettyPrinter
            return PrettyPrinter().pformat(pickle.loads(f.read()))
        finally:
            f.close()

    def run_command(self, cmd, args):
        func = aliases.get(cmd, None)
        if func is None:
            func = complete(commands, cmd, 'command')
        getattr(self, func)(args)

    def save(self):
        filename = self.options.timebook
        if not os.path.exists(os.path.basename(filename)):
            for d in subdirs(filename):
                if os.path.exists(d):
                    break
                else:
                    os.mkdir(d)
        pickled = pickle.dumps(self.serialize(), -1)
        f = file(filename, 'w')
        try:
            f.write(pickled)
        finally:
            f.close()

    def serialize(self):
        sheets = dict([(name, sheet.serialize()) for (name, sheet)
                       in self.iteritems()])
        return {'current': self._current, 'sheets': sheets}

    @command('dump the timebook data file')
    def dump(self, args):
        parser = OptionParser(usage='''usage: %prog dump

Show the unpickled data file.''')
        opts, args = parser.parse_args(args=args)
        print self.pformat()

    @command('show the current timesheet')
    def show(self, args):
        parser = OptionParser(usage='''usage: %prog show [TIMESHEET]

Display a given timesheet. If no timesheet is specified, show the
current timesheet.''')
        opts, args = parser.parse_args(args=args)
        if args:
            sheet_name, sheet = complete(self.sheets, args[0], 'timesheet')
        else:
            sheet_name, sheet = self._current, self[self._current]
        print 'Timesheet %s:' % sheet_name
        if not sheet:
            print '(empty)'
            return

        date = lambda t: datetime.fromtimestamp(t).strftime('%H:%M:%S')
        sheet_total = lambda sheet: str(timedelta(seconds=sheet.total))
        last_day = None
        day_start = 0
        table = [['Day', 'Start      End', 'Duration', 'Notes']]
        for i, e in enumerate(sheet):
            day = datetime.fromtimestamp(e.start).strftime('%b %d, %Y')
            if e.end is None:
                diff = str(timedelta(seconds=int(time.time()) - e.start))
                trange = '%s -' % date(e.start)
            else:
                diff = str(timedelta(seconds=e.end - e.start))
                trange = '%s - %s' % (date(e.start), date(e.end))
            if last_day == day:
                table.append(['', trange, diff, e.desc])
            else:
                if last_day is not None:
                    day_total = sheet_total(sheet[day_start:i])
                    table.append(['', '', day_total, ''])
                table.append([day, trange, diff, e.desc])
                last_day = day
                day_start = i
        table += [['', '', sheet_total(sheet[day_start:]), ''],
                  ['Total', '', sheet_total(sheet), '']]
        pprint_table(table)

    @command('start the timer for the current timesheet')
    def start(self, args, extra=None):
        parser = OptionParser(usage='''usage: %prog start [NOTES...]

Start the timer for the current timesheet. Must be called before stop.
Notes may be specified for this period. This is exactly equivalent to
%prog start; %prog write''')
        parser.add_option('-s', '--switch', dest='switch', type='string',
                          help='Switch to another timesheet before \
starting the timer.')
        opts, args = parser.parse_args(args=args)
        now = int(time.time())
        if opts.switch:
            self.switch([opts.switch])
        sheet = self[self._current]
        if sheet.active:
            print 'error: timesheet already active'
            raise SystemExit(1)
        sheet.append(Entry(now, None, ' '.join(args), extra))
        self.save()

    @command('delete a timesheet')
    def delete(self, args):
        parser = OptionParser(usage='''usage: %prog delete [TIMESHEET]

Delete a timesheet. If no timesheet is specified, delete the current \
timesheet and switch to the default timesheet.''')
        opts, args = parser.parse_args(args=args)
        if args:
            to_delete = args[0]
        else:
            to_delete = self._current
        del self[to_delete]
        if self._current == to_delete:
            self.switch(['default'])
        else:
            self.save()

    @command('show the available timesheets')
    def list(self, args):
        parser = OptionParser(usage='''usage: %prog list

List the available timesheets.''')
        opts, args = parser.parse_args(args=args)
        table = [[' Timesheet', 'Running', 'Today', 'Total time']]
        for name in sorted(self):
            sheet = self[name]
            cur_name = '%s%s' % ('*' if name == self._current
                                     else ' ', name)
            active = '%s' % sheet.running if sheet.active else '--'
            today = str(timedelta(seconds=sheet.today_total))
            total_time = str(timedelta(seconds=sheet.total))
            table.append([cur_name, active, today, total_time])
        pprint_table(table)

    @command('switch to a new timesheet')
    def switch(self, args):
        parser = OptionParser(usage='''usage: %prog switch TIMESHEET

Switch to a new timesheet. This causes all future operation (except switch)
to operate on that timesheet. The default timesheet is called
"default".''')
        opts, args = parser.parse_args(args=args)
        if len(args) != 1:
            parser.error('no timesheet given')
        self._current = args[0]
        if self.get(self._current) is None:
            self[self._current] = Timesheet()
        self.save()

    @command('stop the timer for the current timesheet')
    def stop(self, args):
        parser = OptionParser(usage='''usage: %prog start

Stop the timer for the current timesheet. Must be called after start.''')
        parser.add_option('-v', '--verbose', dest='verbose',
                          action='store_true', help='Show the duration of \
the period that the stop command ends.')
        opts, args = parser.parse_args(args=args)
        now = int(time.time())
        sheet = self[self._current]
        if not sheet.active:
            print 'error: timesheet not active'
            raise SystemExit(1)
        if opts.verbose:
            print running(sheet)
        sheet[-1].end = now
        self.save()

    @command('insert a note into the timesheet')
    def write(self, args):
        parser = OptionParser(usage='''usage: %prog write NOTES...

Inserts a note associated with the currently active period in the \
timesheet.''')
        opts, args = parser.parse_args(args=args)

        sheet = self[self._current]
        if not self.active:
            print 'error: timesheet not active'
            raise SystemExit(1)
        self[self._current][-1].desc = ' '.join(args)
        self.save()

    @command('edit the timesheets data file')
    def edit(self, args):
        from subprocess import call
        from tempfile import mktemp

        parser = OptionParser(usage='''usage: %prog edit

Edit the Python data structures comprising the timesheets data file.
No locking is done, so saving will overwrite any modifications while
editing.

You must keep the timesheet sorted so that list and show work
correctly. This is not done for you.''')
        opts, args = parser.parse_args(args=args)

        filename = mktemp()
        f = file(filename, 'w')
        try:
            f.write(self.pformat())
        finally:
            f.close()
        statbuf = os.stat(filename)

        editor = os.environ.get('EDITOR', 'vi')
        call(editor.split() + [filename])
        if statbuf == os.stat(filename):
            print 'timesheets not modified.'
            os.unlink(filename)
            return

        f = file(filename)
        try:
            self._load(eval(f.read()))
        finally:
            f.close()
        os.unlink(filename)
        self.save()

    @command('display the name of the current timesheet')
    def current(self, args):
        parser = OptionParser(usage='''usage: %prog current

Print the name of the current spreadsheet.''')
        opts, args = parser.parse_args(args=args)
        print self._current

    @command('show all active timesheets')
    def active(self, args):
        parser = OptionParser(usage='''usage: %prog active

Print all active sheets and any messages associate with them.''')
        opts, args = parser.parse_args(args=args)
        table = []
        for name, sheet in self.iteritems():
            if sheet.active:
                table.append([name, sheet[-1].desc])
        if table:
            table.sort()
            pprint_table(table)

    @command('briefly describe the status of the timesheet')
    def info(self, args):
        parser = OptionParser(usage='''usage: %prog info [TIMESHEET]

Print the current sheet, whether it's active, and if so, how long it
has been active and what notes are associated with the current
period.

If a specific timesheet is given, display the same information for that
timesheet instaed.''')
        opts, args = parser.parse_args(args=args)
        if args:
            sheet_name, sheet = complete(self, args[0], 'timesheet')
        else:
            sheet_name, sheet = self._current, self[self._current]
        if sheet.active:
            active = sheet.running + \
                     ' (%s)' % sheet[-1].desc.rstrip('.') \
                     if sheet[-1].desc else ''
        else:
            active = 'not active'
        print '%s: %s' % (sheet_name, active)

def complete(it, lookup, key_desc):
    partial_match = None
    for i in it:
        if i == lookup:
            return i
        if i.startswith(lookup):
            if partial_match is not None:
                raise AmbiguousLookup('ambiguous %s %r' %
                                      (key_desc, lookup))
            partial_match = i
    if partial_match is None:
        raise NoMatch('no such %s %r.' % (key_desc, lookup))
    else:
        return partial_match

def subdirs(path):
    path = os.path.abspath(path)
    last = path.find(os.path.sep)
    while True:
        if last == -1:
            break
        yield path[:last + 1]
        last = path.find(os.path.sep, last + 1)

def pprint_table(table):
    widths = [3 + max([len(row[col]) for row in table])
              for col in xrange(len(table[0]))]
    for row in table:
        print ''.join([cell + ' ' * (spacing - len(cell))
                       for (cell, spacing) in zip(row, widths)])

def parse_options():
    from optparse import OptionParser
    cmd_descs = ['%s - %s' % (k, commands[k])
                 for k in sorted(commands.keys())]
    parser = OptionParser(usage='''usage: %%prog [OPTIONS] COMMAND \
[ARGS...]

where COMMAND is one of:
    %s''' % '\n    '.join(cmd_descs))
    parser.disable_interspersed_args()
    parser.add_option('-C', '--config', dest='config',
                      default=DEFAULTS['config'], help='Specify an \
alternate configuration file (default: %r).' % DEFAULTS['config'])
    parser.add_option('-b', '--timebook', dest='timebook',
                      default=DEFAULTS['timebook'], help='Specify an \
alternate timebook file (default: %r).' % DEFAULTS['timebook'])
    options, args = parser.parse_args()
    if len(args) < 1:
        parser.error('no command specified')
    return options, args

def parse_config(filename):
    config = ConfigParser()
    f = open(filename)
    try:
        config.readfp(f)
    finally:
        f.close()
    return config

def main():
    options, args = parse_options()
    config = parse_config(options.config)
    book = Timebook(options, config)
    cmd, args = args[0], args[1:]
    book.run_command(cmd, args)

if __name__ == '__main__':
    main()
