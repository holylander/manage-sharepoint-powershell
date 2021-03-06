Import-Module -Force $PSScriptRoot\..\resources\SP_tools.psm1;

function getListItems() {
    param(
        [System.Collections.Hashtable] $site, ## provides the $site object returned by the SP_connection_manager ( site connection context )
        [System.Array]$fields,  ## fields that want to be requested
        [string]$list_name,
        [System.Management.Automation.ScriptBlock]$filter      ## Filter example: {$_.FieldValues.Category -eq 'home'}
    )

    if (!$list_name) {
        $list_name = [String]$(Read-Host -Prompt 'Please type the sharepoint TARGET list name')
    }

    try {
        Write-Host @("Trying to retrieve items from list: '{0}', site: '{1}' " -f $list_name, $site.siteTitleFormated)
        if ($filter) {
            Write-Host @("Filtering items where: '{0}' " -f $filter)
            $returned_items = Get-PnPListItem -ErrorAction Stop -Connection $site.siteContext -List $list_name -Fields $fields | Where-Object $filter;
        }
        else {
            $returned_items = Get-PnPListItem -ErrorAction Stop -Connection $site.siteContext -List $list_name -Fields $fields ;
        }

        Write-Host @('OK: {0} item(s) were returned' -f $returned_items.Length)
        return @{
            "items"     = $returned_items;
            "fields"    = if ($fields) { $fields } else { "All in item content type" };
            "total"     = $returned_items.count
            "list_name" = $list_name;
        };
    }
    catch {
        Write-Host ("There has been an error trying to retrive the items from list '{1}'.`nError details: {0} " -f ($_.Exception.Message, $list_name))
    }

}
function copyListsItems( ) {
    param(
        [System.Collections.Hashtable] $item_collection, ## need to provide a collection object returned by getListItems
        [System.Collections.Hashtable] $site, ## need to provide the $site object returned by the SP_connection_manager
        [System.Array]$fields, # if empty, use the fields provided in the item_collection
        [string]$list_name
    )
    try {
        if ($item_collection.total -le 0 ) {
            throw 'FAIL: There are no items no be copied.';
        }

        if ($fields -and ($($fields.count) -ne $($item_collection.fields.count) )) {
            throw 'FAIL: number of target and source fields differ.';
        }
        else {
            $fields = $item_collection.fields
        }

        if (!$list_name) { $list_name = $item_collection.list_name }

        # loop until answer is given.
        while ($copy_confirm -ne "y") {
            if ($copy_confirm -eq 'n') {
                throw 'ABORT: byez...';
                #Write-Host "ABORT: byez..."
                #return $null # exit
            }
            $copy_confirm = Read-Host "Would you like to copy these ($($item_collection.total)) items to '$list_name', on site '$($site.siteTitleFormated)' ? (y/n)?";
        }

        #Create the arrays that will hold the info of the items than returned error, and the successful actions as well
        $items_copied_ok = @{"items" = @(); "total" = 0 };
        $items_copy_fail = @{"items" = @(); "total" = 0 };

        # create the data structure that will be copied into the item
        $item_collection.items | ForEach-Object {
            $item = $_
            $item_values = generateItemValues -fields $item_collection.fields -item $item

            #try to save the item on target list
            $new_list_item = Add-PnPListItem -ErrorAction Inquire -Connection $site.siteContext -List $list_name -Values $item_values;
            if ($new_list_item) {
                <# Write-Host "OK: New item ($($new_list_item.Id)) was saved in to list: '$list_name', on site: '$($site.siteTitleFormated)'. Source item '$($item.FieldValues.GetEnumerator()  | Select-Object -first 1 key)': '$($item.FieldValues.GetEnumerator()  | Select-Object -first 1 value)'.";        
                 #>
                 Write-Host "OK: New item ($($new_list_item.Id)) was saved in to list: '$list_name', on site: '$($site.siteTitleFormated)'. Source item ID: '$($item.FieldValues.ID)'.";        
                
                $items_copied_ok.items += @{"ok_id-$($new_list_item.Id)" = $item.FieldValues };
                $items_copied_ok.total += 1;
            }
            else {
                Write-Host "FAIL: Item '$($item.FieldValues.GetEnumerator()  | Select-Object -first 1 key)': '$($item.FieldValues.GetEnumerator()  | Select-Object -first 1 value)' was not copied. ";
                $items_copy_fail.items += @{"error_id-$($item.Id)" = $item.FieldValues };
                $items_copy_fail.total += 1;
            }
            ##TODO: non blocking / async execution
            ##TODO: take attachments
            ##TODO: take security

            Remove-Variable item_values;
        };
        return @{"ok" = $items_copied_ok; "failed" = $items_copy_fail }
    }
    catch {
        Write-Host @("There has been an error trying to copy items to '{1}'.`nError details: {0}" -f ($_.Exception.Message), $site.siteTitleFormated);
    }
}
function updateListsItem ( ) {
    param(
        ## need to provide the $site object returned by the SP_connection_manager
        [System.Collections.Hashtable] $site,
        ## need to provide the sharepoint list item object
        $item,
        ## to be provided along a handler, in case you you extra params in the handler function
        [System.Collections.Hashtable] $item_collection,
        ## target list name
        [string] $list_name,
        ## value to be updated, example: $changes= @{"MDDDisplayDesc" = "0"};    ( boolean must be given as strings)
        [System.Collections.Hashtable] $changes,
        ## used from transforming data before update
        [System.Management.Automation.ScriptBlock]$handler
    )
    $updated_item = $null;
    try {
        Write-Host @("Trying to update item (ID: {0}) on list '{1}' " -f $item.Id, $list_name);
        if ($handler) {
            #what we want to do is to introduce some kind of manipulation on the current row.
            $changes = Invoke-Command $handler -ArgumentList $item, $item_collection.items;
            #$updated_item=Set-PnPListItem -List $list_name -Identity $item.Id -Values $handler_result -Connection $site.siteContext;
        }
        if ($changes) {
            #some kind of static change, equal to every row.
            $updated_item = Set-PnPListItem -List $list_name -Identity $item.Id -Values $changes -Connection $site.siteContext;
            Write-Host @("OK: List Item '{0}' has been updated." -f $item.Id);
        }
    }
    catch {
        throw @("FAIL: Could not modify List Item '{0}'" -f $item.Id);
    }
    return $updated_item
}
function copyPublishingItems( ) {
    param(
        [System.Collections.Hashtable] $item_collection, ## need to provide a collection object returned by getListItems
        [System.Collections.Hashtable] $site, ## need to provide the $site object returned by the SP_connection_manager
        [string]$list_name,
        [array]$include_weparts ## enable copying the webparts on publishingPageContent  that are going to be copied.
    )
    try {
        if ($item_collection.total -le 0 ) {
            throw 'FAIL: There are no items no be copied.';
        }

        if ($fields -and ($($fields.count) -ne $($item_collection.fields.count) )) {
            throw 'FAIL: number of target and source fields differ.';
        }
        else { $fields = $item_collection.fields }

        if (!$list_name) { $list_name = $item_collection.list_name }

        # loop until answer is given.
        while ($copy_confirm -ne "y") {
            if ($copy_confirm -eq 'n') {
                throw 'ABORT: byez...';
            }
            $copy_confirm = Read-Host "Would you like to copy these ($($item_collection.total)) items to '$list_name', on site '$($site.siteTitleFormated)' ? (y/n)?";
        }

        #Create the arrays that will hold the info of the items than returned error, and the successful actions as well
        $items_copied_ok = @{"items" = @(); "total" = 0 };
        $items_copy_fail = @{"items" = @(); "total" = 0 };

        # create the data structure that will be copied into the item
        $item_collection.items | ForEach-Object {
            $item = $_
            # work out some foundational column info like page url, page layout...
            $page_layout = $item.FieldValues.PublishingPageLayout.Url.Substring($item.FieldValues.PublishingPageLayout.Url.LastIndexOfAny("/") + 1).replace(".aspx", "");
            $page_temp_name = $($item.FieldValues.FileLeafRef.Replace(".aspx", "") + "-" + $(Get-Random -Maximum 10000))
            # add the source publishing page on target library
            Add-PnPPublishingPage -Connection $site.siteContext -PageName $page_temp_name -OutVariable $test -ErrorAction Inquire -Title $item.Title -PageTemplateName $page_layout
            $created_page = Get-PnPListItem -Connection $site.siteContext  -List $list_name -Query ("<View><Query><Where><Eq><FieldRef Name='Title'/><Value Type='Text'>" + $page_temp_name + "</Value></Eq></Where></Query></View>");

            if ($created_page) {
                Write-Host "OK: Publising Page has been created: ID ($($created_page.Id)), Title: $($created_page.FieldValues.Title)"

                # copy publishing page webparts if needed
                if ($include_weparts){
                    $new_webpart_code=copyWebparts -src_item $item -target_url $($created_page.FieldValues.FileRef)
                    $item.FieldValues.PublishingPageContent+=$new_webpart_code
                }
                #builds changes values arry in order to update newly create page with values from original page
                $changes = generateItemValues -fields $fields -item $item   # $changes example : $changes=@{"ID" = 23}

                $updated_page = updateListsItem -site $site -item $created_page -list_name $list_name -changes $changes
                If ($updated_page) {
                    $items_copied_ok.items += @{"ok_id-$($item.Id)" = $item.FieldValues };
                    $items_copied_ok.total += 1;
                    Write-Host "OK: Publising Page has been copied: ID ($($updated_page.Id)), Title: $($updated_page.FieldValues.Title)"
                }
                else {
                    $items_copy_fail.items += @{"error_id-$($item.Id)" = $item.FieldValues };
                    $items_copy_fail.total += 1;
                    Write-Host 'There has been a problem updating the copied item';
                }
            }

            else {
                throw 'There has been a problem creating the item';
            }
        };
        return @{"ok" = $items_copied_ok; "failed" = $items_copy_fail }
    }
    catch {
        Write-Host @("There has been an error trying to copy publishing pages to '{1}'.`nError details: {0}" -f ($_.Exception.Message), $site.siteTitleFormated);
    }
}

Export-ModuleMember -Function getListItems, copyListsItems, updateListsItem, copyPublishingItems;