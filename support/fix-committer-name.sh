#!/bin/sh

# Simple script used for rewriting committer name to docelic.
 
git filter-branch --env-filter '
 
an="$GIT_AUTHOR_NAME"
am="$GIT_AUTHOR_EMAIL"
cn="$GIT_COMMITTER_NAME"
cm="$GIT_COMMITTER_EMAIL"
 
cn="Davor Ocelic"
cm="docelic@spinlocksolutions.com"
 
an="Davor Ocelic"
am="docelic@spinlocksolutions.com"

 
export GIT_AUTHOR_NAME="$an"
export GIT_AUTHOR_EMAIL="$am"
export GIT_COMMITTER_NAME="$cn"
export GIT_COMMITTER_EMAIL="$cm"
'

