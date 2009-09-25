# site.pp

filebucket { main: server => "puppet" }

# Global defaults

File { backup => main }
# Don't distribute version control metadata
File { ignore => [ '.svn', '.git', 'CVS' ] }

Exec { path => "/usr/bin:/usr/sbin/:/bin:/sbin" }

