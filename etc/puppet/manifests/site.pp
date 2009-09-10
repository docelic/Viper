filebucket { server:
	server => "puppet"
}

# don't distribute version control metadata
#File { ignore => ['.svn', '.git', 'CVS' ] }
