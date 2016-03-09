# Description:
#   Jira lookup when issues are heard
#
# Dependencies:
#   None
#
# Configuration:
#   HUBOT_JIRA_LOOKUP_USERNAME
#   HUBOT_JIRA_LOOKUP_PASSWORD
#   HUBOT_JIRA_LOOKUP_URL
#   HUBOT_JIRA_LOOKUP_IGNORE_USERS (optional, format: "user1|user2", default is "jira|github")
#   HUBOT_JIRA_LOOKUP_INC_DESC
#   HUBOT_JIRA_LOOKUP_MAX_DESC_LEN
#   HUBOT_JIRA_LOOKUP_SIMPLE
#   HUBOI_JIRA_LOOKUP_TIMEOUT
#
# Commands:
#   hubot set jira_lookup_style [long|short]
#   hubot show approvers - shows the list of jira approvers
#   hubot pending crs - shows the list of pending crs
#   hubot approved crs - shows the list of approved crs this week
#   hubot implemented crs - shows the list of implemented crs this week
#   hubot approve CR-XX [comment]
#
# Author:
#   Matthew Finlayson <matthew.finlayson@jivesoftware.com> (http://www.jivesoftware.com)
#   Benjamin Sherman  <benjamin@jivesoftware.com> (http://www.jivesoftware.com)
#   Dustin Miller <dustin@sharepointexperts.com> (http://sharepointexperience.com)
#   Jordan Walsh <jwalsh@whispir.com>

## Prevent the bot sending the jira ticket details too often in any channel

## Store when a ticket was reported to a channel
# Key:   channelid-ticketid
# Value: timestamp
# 
LastHeard = {}

RecordLastHeard = (robot,channel,ticket) ->
  ts = new Date()
  key = "#{channel}-#{ticket}"
  LastHeard[key] = ts

CheckLastHeard = (robot,channel,ticket) ->
  now = new Date()
  key = "#{channel}-#{ticket}"
  last = LastHeard[key] || 0
  timeout =  process.env.HUBOT_JIRA_LOOKUP_TIMEOUT || 15
  limit = (1000 * 60 * timeout)
  diff = now - last

  #@robot.logger.debug "Check: #{key} #{diff} #{limit}"
  
  if diff < limit
    return yes
  no

StylePrefStore = {}

SetRoomStylePref = (robot, msg, pref) ->
  room  = msg.message.user.reply_to || msg.message.user.room
  StylePrefStore[room] = pref
  storePrefToBrain robot, room, pref
  msg.send "Jira Lookup Style Set To #{pref} For #{room}"

GetRoomStylePref = (robot, msg) ->
  room  = msg.message.user.reply_to || msg.message.user.room
  def_style = process.env.HUBOT_JIRA_LOOKUP_STYLE || "long"
  rm_style = StylePrefStore[room]
  if rm_style
    return rm_style
  def_style
  
storePrefToBrain = (robot, room, pref) ->
  robot.brain.data.jiralookupprefs[room] = pref

syncPrefs = (robot) ->
  nonCachedPrefs = difference(robot.brain.data.jiralookupprefs, StylePrefStore)
  for own room, pref of nonCachedPrefs
    StylePrefStore[room] = pref

  nonStoredPrefs = difference(StylePrefStore, robot.brain.data.jiralookupprefs)
  for own room, pref of nonStoredPrefs
    storePrefToBrain robot, room, pref

difference = (obj1, obj2) ->
  diff = {}
  for room, pref of obj1
    diff[room] = pref if room !of obj2
  return diff

#-----------------------------------------------------------------------------#

module.exports = (robot) ->
  robot.brain.data.jiralookupprefs or= {}
  robot.brain.on 'loaded', =>
    syncPrefs robot
  
  ignored_users = process.env.HUBOT_JIRA_LOOKUP_IGNORE_USERS
  if ignored_users == undefined
    ignored_users = "jira|github|bubbles|thanksjen|harold"

  #console.log "Ignore Users: #{ignored_users}"

  #Allows a user to modify whether they should display short or long form descriptions
  robot.respond /set jira_lookup_style (long|short)/, (msg) ->
    SetRoomStylePref robot, msg, msg.match[1]

  #Responds to any Jira ticket ID
  robot.hear /\b[a-zA-Z]{2,12}-[0-9]{1,10}\b/ig, (msg) ->

    return if msg.message.user.name.match(new RegExp(ignored_users, "gi"))
    return if msg.message.match(new RegExp("^approve", "gi"))

    #@robot.logger.debug "Matched: "+msg.match.join(',')

    reportIssue robot, msg, issue for issue in msg.match

  #Display the approvers that are being used
  robot.hear /^(show)?\s?approvers/i, (msg) ->
    firstApprovers = ["yasir","manojperera","apetronzio","jordan.walsh","romilly","uali"]
    secondApprovers = ["apetronzio","romilly","alow","aarmani","arussell","franco"]

    msg.send "*First Approvers (Technical)*: #{firstApprovers}"
    msg.send "*Second Approvers (Business)*: #{secondApprovers}"

  #Displays a listing of the pending CRs from JIRA
  robot.hear /^pending crs/i, (msg) ->

    filter = "project+%3D+\"Change+Request\"+AND+status+in+(\"First+Approval\",\"Second+Approval\")+order+by+created+asc"
    msg.send "_Searching jira for CRs that are awaiting approval_\n"
    searchIssues robot, msg, filter

  #Displays a listing of the pending CRs from JIRA
  robot.hear /^approved crs/i, (msg) ->

    filter = "project+%3D+\"Change+Request\"+and+status+in+(\"Ready+for+Implementation\")+and+createdDate+>+startOfWeek()+order+by+createdDate+asc"
    msg.send "_Searching jira for CRs that have been approved this week_\n"
    searchIssues robot, msg, filter

  #Displays a listing of the pending CRs from JIRA
  robot.hear /^implemented crs/i, (msg) ->

    filter = "project+%3D+\"Change+Request\"+and+status+in+(\"Implemented\")+and+createdDate+>+startOfWeek()+order+by+createdDate+asc"
    msg.send "_Searching jira for CRs that have been implemented this week_\n"
    searchIssues robot, msg, filter

  #Transition a CR through the workflow
  robot.hear /^approve\s(\b[a-zA-Z]{2,12}-[0-9]{1,10}\b)\s?(.*)/i, (msg) ->
    issue = ""
    comment = ""

    #Get the issue key
    if msg.match.length > 0
      issue = msg.match[1]

    #Get the comment
    if msg.match.length > 1
      comment = msg.match[2]

    if issue == ""
      msg.send "No issue provided for approval. Format is: approve \"issuekey\""
    else
      approveIssue robot, msg, issue, comment

approveIssue = (robot, msg, issue, comment) ->

  user = process.env.HUBOT_JIRA_LOOKUP_USERNAME
  pass = process.env.HUBOT_JIRA_LOOKUP_PASSWORD
  url = process.env.HUBOT_JIRA_LOOKUP_URL

  firstApprovers = ["yasir","manojperera","apetronzio","jordan.walsh","romilly","uali"]
  secondApprovers = ["apetronzio","romilly","alow","aarmani","arussell","franco"]
  
  #hack to get jira working
  process.env['NODE_TLS_REJECT_UNAUTHORIZED'] = '0';  

  auth = 'Basic ' + new Buffer(user + ':' + pass).toString('base64')

  robot.http("#{url}/rest/api/latest/issue/#{issue}/transitions")
    .headers(Authorization: auth, Accept: 'application/json')
    .get() (err, res, body) ->
      try
        json = JSON.parse(body)

        if json.errorMessages && json.errorMessages.length > 0
          msg.send json.errorMessages[0]
        else
          
          transitions = json.transitions

          if transitions.length == 0
            msg.send "#{issue} cannot be approved."
          else 
            #find the approval transition

            transition = false
            err = false
            message = ""

            for t in transitions
              transitionId = t.id

              transitionData = {
                transition: {
                    id: "#{transitionId}"
                }
              }

              currentUser = msg.message.user.name

              if comment != "" then comment = currentUser + ": " + comment + "\n\n"

              commentData = {
                body: "#{comment}Approved by #{msg.message.user.name} (via #changeapprovals slack channel)"
              }

              if t.name == "Approve (1st)" && currentUser in firstApprovers

                transition = true
                message = "#{issue} has been approved. Awaiting 2nd Approval. \n\nAttention: " + secondApprovers

              else if t.name == "Approve (2nd)" && currentUser in secondApprovers

                transition = true
                message = "#{issue} has been approved. Ready for Implementation."
              

              if transition
                #Transition the issue
                robot.http("#{url}/rest/api/latest/issue/#{issue}/transitions")
                  .header("Authorization", auth)
                  .header("Content-Type", 'application/json')
                  .header("Accept", 'application/json')
                  .post(JSON.stringify(transitionData)) (err, res, body) ->
                    msg.send message

                #Add a comment
                robot.http("#{url}/rest/api/latest/issue/#{issue}/comment")
                  .header("Authorization", auth)
                  .header("Content-Type", 'application/json')
                  .header("Accept", 'application/json')
                  .post(JSON.stringify(commentData)) (err, res, body) ->
                    #console.log err

                break
              else
                !err && msg.send "#{issue} could not be approved. It isn't in a valid state, or #{currentUser} doesn't have appropriate permission to approve."
                err = true

searchIssues = (robot, msg, filter) ->
  user = process.env.HUBOT_JIRA_LOOKUP_USERNAME
  pass = process.env.HUBOT_JIRA_LOOKUP_PASSWORD
  url = process.env.HUBOT_JIRA_LOOKUP_URL
  
  #hack to get jira working
  process.env['NODE_TLS_REJECT_UNAUTHORIZED'] = '0';  

  auth = 'Basic ' + new Buffer(user + ':' + pass).toString('base64')

  robot.http("#{url}/rest/api/latest/search?jql=#{filter}")
    .headers(Authorization: auth, Accept: 'application/json')
    .get() (err, res, body) ->
      try
        json = JSON.parse(body)

        total = json.total

        if total == 1
          msg.send "#{total} result returned."
        else if total == 0
          msg.send "No results returned."
        else
          msg.send "#{total} results returned."

        for issue in json.issues
          key = issue.key || ""
          summary = issue.fields.summary || ""
          issueType = issue.fields.issuetype.name || ""
          requestor = issue.fields.reporter.displayName || ""
          assignee = issue.fields.assignee.displayName || ""
          startDate = issue.fields.customfield_12431 || ""
          endDate = issue.fields.customfield_12440 || ""
          status = issue.fields.status.name || ""
          risk = if issue.fields.customfield_12432 then issue.fields.customfield_12432.value else ""

          msg.send "*#{key}: #{summary}*\nStatus: #{status}\nRequestor: #{requestor}\nRisk: #{risk}\nScheduled Start: #{startDate}\nScheduled End: #{endDate}\n"

      catch error
        msg.send "Something went wrong with the jira lookup.. get @jordan.walsh to check the logs for you."
        console.log error 

reportIssue = (robot, msg, issue) ->
  room  = msg.message.user.reply_to || msg.message.user.room
    
  #@robot.logger.debug "Issue: #{issue} in channel #{room}"

  return if CheckLastHeard(robot, room, issue)

  RecordLastHeard robot, room, issue

  if process.env.HUBOT_JIRA_LOOKUP_SIMPLE is "true"
    msg.send "Issue: #{issue} - #{process.env.HUBOT_JIRA_LOOKUP_URL}/browse/#{issue}"
  else
    user = process.env.HUBOT_JIRA_LOOKUP_USERNAME
    pass = process.env.HUBOT_JIRA_LOOKUP_PASSWORD
    url = process.env.HUBOT_JIRA_LOOKUP_URL

    #hack to get jira working
    process.env['NODE_TLS_REJECT_UNAUTHORIZED'] = '0';

    inc_desc = process.env.HUBOT_JIRA_LOOKUP_INC_DESC
    if inc_desc == undefined
       inc_desc = "Y"
    max_len = process.env.HUBOT_JIRA_LOOKUP_MAX_DESC_LEN

    auth = 'Basic ' + new Buffer(user + ':' + pass).toString('base64')

    robot.http("#{url}/rest/api/latest/issue/#{issue}")
      .headers(Authorization: auth, Accept: 'application/json')
      .get() (err, res, body) ->
        try
          json = JSON.parse(body)

          if json.errorMessages && json.errorMessages.length > 0
            msg.send json.errorMessages[0]
          else
            data = {
              'key': {
                key: 'Key'
                value: issue
              }
              'summary': {
                key: 'Summary'
                value: json.fields.summary || null
              }
              'link': {
                key: 'Link'
                value: "#{process.env.HUBOT_JIRA_LOOKUP_URL}/browse/#{json.key}"
              }
              'description': {
                key: 'Description',
                value: json.fields.description || null
              }
              'assignee': {
                key: 'Assignee',
                value: (json.fields.assignee && json.fields.assignee.displayName) || 'Unassigned'
              }
              'reporter': {
                key: 'Reporter',
                value: (json.fields.reporter && json.fields.reporter.displayName) || null
              }
              'created': {
                key: 'Created',
                value: json.fields.created && (new Date(json.fields.created)).toLocaleString() || null
              }
              'status': {
                key: 'Status',
                value: (json.fields.status && json.fields.status.name) || null
              }
            }

            style = GetRoomStylePref robot, msg
              
            if style is "long"
              fallback = "*#{data.key.value}: #{data.summary.value}*\n"
              if data.description.value? and inc_desc.toUpperCase() is "Y"
                if max_len and data.description.value?.length > max_len
                  fallback += "*Description:*\n #{data.description.value.substring(0,max_len)} ...\n"
                else
                  fallback += "*Description:*\n #{data.description.value}\n"
              fallback += "*Assignee*: #{data.assignee.value}\n*Status*: #{data.status.value}\n*Link*: #{data.link.value}\n"
            else
              fallback = "#{data.key.value}: #{data.summary.value} [status #{data.status.value}; assigned to #{data.assignee.value} ] #{data.link.value}"
              

            if process.env.HUBOT_SLACK_INCOMING_WEBHOOK?
              if style is "long"
                robot.emit 'slack.attachment',
                  message: msg.message
                  content:
                    fallback: fallback
                    title: "#{data.key.value}: #{data.summary.value}"
                    title_link: data.link.value
                    text: data.description.value
                    fields: [
                      {
                        title: data.reporter.key
                        value: data.reporter.value
                        short: true
                      }
                      {
                        title: data.assignee.key
                        value: data.assignee.value
                        short: true
                      }
                      {
                        title: data.status.key
                        value: data.status.value
                        short: true
                      }
                      {
                        title: data.created.key
                        value: data.created.value
                        short: true
                      }
                    ]
              else
                robot.emit 'slack.attachment',
                  message: msg.message
                  content:
                    fallback: fallback
                    title: "#{data.key.value}: #{data.summary.value}"
                    title_link: data.link.value
                    text: "Status: #{data.status.value}; Assigned: #{data.assignee.value}"
            else
              msg.send fallback
        catch error
          msg.send "Something went wrong with the jira lookup.. get @jordan.walsh to check the logs for you, he's good at that sort of thing."
          console.log error
