#########################################
# AddTable-ToCT
#
# This script is used for adding a table to Change Tracking
# via tesla. 
#
# Generally, it should be called by the InitializeDB script,
# which is able to read tesla config files to determine most
# of the parameters to pass in. 
#########################################
Param(
 [Parameter(Mandatory=$true,Position=1)][string]$master,
 [Parameter(Mandatory=$true,Position=2)][string]$masterdb,
 [Parameter(Mandatory=$true,Position=3)][string]$slave,
 [Parameter(Mandatory=$true,Position=4)][string]$slavedb,
 [Parameter(Mandatory=$true,Position=5)][string]$slavetype,
 [Parameter(Mandatory=$true,Position=6)][string]$table,
 [Parameter(Mandatory=$false)][string]$schema="dbo", #schema the table lives in
 [Parameter(Mandatory=$false)][string]$user, #username to use when connecting to the slave
 [Parameter(Mandatory=$false)][string]$password, #ctripledes encrypted password to use when connecting to the slave
 [Parameter(Mandatory=$false)][xml]$columnlist, #XML list of columns to copy to the slave
 [Parameter(Mandatory=$false)][xml]$columnmodifiers, #XML column modifiers for shortening fields
 [Parameter(Mandatory=$false)][int]$netezzastringlength, #max length for netezza strings
 [Parameter(Mandatory=$false)][string]$mappingsfile, #file for data mappings for netezza slaves
 [Parameter(Mandatory=$false)][string]$sshuser, #user for sshing to netezza
 [Parameter(Mandatory=$false)][string]$pkpath, #private key path for ssh
 [Parameter(Mandatory=$false)][string]$plinkpath, #path to plink.exe
 [Parameter(Mandatory=$false)][string]$nzloadscript, #path to netezza load script on the netezza box
 [Parameter(Mandatory=$false)][string]$bcppath, #path to bcp files out to for netezza
 [switch]$reinitialize, #just reinitialize the table, don't drop/recreate it
 [switch]$notlast, #is this the last slave being (re)initialized? we only update tblCTInitialize if this the last one
 [switch]$notfirstshard #for sharding, we only truncate/recreate the slave table for the first shard
 
)
If ("MSSQL","Netezza" -NotContains $slavetype) {
    Throw ("Slave type $($slavetype) is not valid!")
}

[System.Reflection.Assembly]::LoadWithPartialName('Microsoft.SqlServer.SMO') | out-null
# Load DB module from current directory
Push-Location (Split-Path -Path $MyInvocation.MyCommand.Definition -Parent)
Import-Module .\Modules\DB
$ErrorActionPreference = "Stop"
$error.clear()
###############################
# Constants - we should probably do something better about these
###############################
if ($slavetype -eq "Netezza") {
    set-alias plink $plinkpath

    $bcppath = $bcppath.TrimEnd("\") + $slavedb.ToLower()
    if (!(Test-path $bcppath)) {
        mkdir $bcppath | out-null
    }
    $bcppath += $table.ToLower() + ".txt"
}

#set column lists if they are specified
$columnarray = @()
if ($columnlist -ne $null) {
    foreach($node in $columnlist.SelectNodes("//column")) {
        $columnarray += $node.InnerText
    }
}

#set column modifiers if they are specified
$modifiertable = @{}
if ($columnmodifiers -ne $null) {
    foreach ($node in $columnmodifiers.SelectNodes("//columnModifier")) {
        if ($node.type -eq "ShortenField") {
            $modifiertable[$node.columnName] = $node.length
        }
    }
}

#quick shortcut function for running queries on the slave
Function Invoke-Slave($query) {
    if ($slavetype -eq "MSSQL") {
        Invoke-SqlCmd2 -serverinstance $slave -database $slavedb -query $query
    } elseif ($slavetype -eq "Netezza") {
        Invoke-NetezzaQuery -serverinstance $slave -database $slavedb -query $query -user $username -password $password
    }
}

#for netezza, get column escaping expression
Function Get-ColExpression($name, $type) {
    $stringtypes = @([Microsoft.SqlServer.Management.Smo.SqlDataType]::Text,
    [Microsoft.SqlServer.Management.Smo.SqlDataType]::NText,
    [Microsoft.SqlServer.Management.Smo.SqlDataType]::Char,
    [Microsoft.SqlServer.Management.Smo.SqlDataType]::NChar,
    [Microsoft.SqlServer.Management.Smo.SqlDataType]::NVarChar,
    [Microsoft.SqlServer.Management.Smo.SqlDataType]::NVarCharMax,
    [Microsoft.SqlServer.Management.Smo.SqlDataType]::VarChar,
    [Microsoft.SqlServer.Management.Smo.SqlDataType]::VarCharMax
    )

    if ($stringtypes -contains $type.SqlDataType) {
        return [string]::Format("ISNULL(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(cast([{0}] as varchar(max))," `
        + "'\', '\\'),CHAR(13)+CHAR(10),' '),'\""', '\'+'\""'),'|', ','),CHAR(10), ' '), " `
        + "'NULL', '\NULL'), 'NULL') as '{0}'", $name)
    } else {
        return $name
    }
}

#renames netezza reserved words
Function Map-ReservedWordNetezza($col) {
    $reservedwords = @{"CTID" = "CT_ID"; 
    "OID" = "O_ID";
    "XMIN" = "X_MIN";
    "CMIN" = "C_MIN";
    "XMAX" = "X_MAX";
    "CMAX" = "C_MAX";
    "TABLEOID" = "TABLE_O_ID"
    }
    if ($reservedwords.ContainsKey($col.ToUpper())) {
        return $reservedwords[$col.ToUpper()]
    }
    return $col
}

#we'll use the results of this loop in two separate places below, so just handle it now
if ($slavetype -eq "Netezza") {
    [TeslaSQL.DataType]::LoadDataMappingsFromFile($mappingsfile)

    $shortenedtypes = @([Microsoft.SqlServer.Management.Smo.SqlDataType]::Binary,
    [Microsoft.SqlServer.Management.Smo.SqlDataType]::VarBinary,
    [Microsoft.SqlServer.Management.Smo.SqlDataType]::VarBinaryMax,
    [Microsoft.SqlServer.Management.Smo.SqlDataType]::Char,
    [Microsoft.SqlServer.Management.Smo.SqlDataType]::NChar,
    [Microsoft.SqlServer.Management.Smo.SqlDataType]::NVarChar,
    [Microsoft.SqlServer.Management.Smo.SqlDataType]::NVarCharMax,
    [Microsoft.SqlServer.Management.Smo.SqlDataType]::VarChar,
    [Microsoft.SqlServer.Management.Smo.SqlDataType]::VarCharMax)

    $shortenednumerictypes = @([Microsoft.SqlServer.Management.Smo.SqlDataType]::Decimal,
    [Microsoft.SqlServer.Management.Smo.SqlDataType]::Numeric)

    $con = new-object ("Microsoft.SqlServer.Management.Common.ServerConnection") $master
    $con.Connect()
    $server = new-object ("Microsoft.SqlServer.Management.Smo.Server") $con
    $database = $server.Databases[$masterdb]
    $smotable = $Database.Tables.Item($table)

    $cols = @()
    $colexpressions = @()
    foreach ($column in $smotable.Columns) {
        if (($columnarray.Length -eq 0) -or ($columnarray -contains $column.Name)) {
            $typename = $column.DataType.Name
            $moddatatype = [TeslaSQL.DataType]::MapDataType("MSSQL", "Netezza", $typename)
            if ($typename -ne $moddatatype) {
                $col = (Map-ReservedWordNetezza $column.Name) + " " + $typename 
                if ($column.Nullable) {
                    $col += " NULL"
                } else {
                    $col += " NOT NULL"
                }
                $colexpressions += Get-ColExpression (Map-ReservedWordNetezza $column.Name) $column.DataType
                continue
            }
            if ($shortenedtypes -Contains($column.DataType.SqlDataType)) {
                $mod = $null
                if ($modifiertable.ContainsKey($column.Name)) {
                    $typename += "(" + $modifiertable[$column.Name].ToString() + ")"
                } else {
                    $typename += "("
                    if (($col.DataType.MaximumLength -gt $netezzastringlength) -or ($col.DataType.MaximumLength -lt 1)) {
                        $typename += $netezzastringlength.ToString()
                    } else {
                        $typename += $col.DataType.MaximumLength.ToString()
                    }
                    $typename += ")"
                }
            } elseif ($shortenednumerictypes -Contains($column.DataType.SqlDataType)) {
                $typename += "(" + $col.DataType.NumericPrecision.ToString() + "," + $col.DataType.NumericScale.ToString() + ")"
            }    
            $col = (Map-ReservedWordNetezza $column.Name) + " " + $typename 
            if ($column.Nullable) {
                $col += " NULL"
            } else {
                $col += " NOT NULL"
            }
            $cols += $col
            $colexpressions += Get-ColExpression (Map-ReservedWordNetezza $column.Name) $column.DataType
        }
    }
}

#for sharding, we only drop/truncate/recreate the table on the slave for the first shard
if (!$notfirstshard) {
    #for reinitializing, don't drop/recreate the table. just truncate
    if ($reinitialize) {
        if ($slavetype -eq "Netezza") {
            $query = "TRUNCATE TABLE $table"
        } elseif ($slavetype -eq "MSSQL") {
            $query = "TRUNCATE TABLE " + $schema + "." + $table
        }
        Invoke-Slave -query $query
    } elseif ($slavetype -eq "MSSQL") {
        #drop table or view if exists
        $query = "
        IF EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_TYPE = 'BASE TABLE' AND TABLE_NAME = '$table')
    	   DROP TABLE $table
        ELSE IF EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_TYPE = 'VIEW' AND TABLE_NAME = '$table')
    	   DROP VIEW $table"
        Invoke-Slave -query $query
        
        #table creation command
        $creationcmd = "CREATE TABLE [$schema].[$table] ("
        #get columns from master
        $query = "SELECT COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH, NUMERIC_SCALE, NUMERIC_PRECISION, IS_NULLABLE
        FROM INFORMATION_SCHEMA.COLUMNS WITH(NOLOCK)
        WHERE TABLE_NAME = '$table' AND TABLE_SCHEMA = '$schema'" 
        $columns = Invoke-SqlCmd2 -serverinstance $master -database $masterdb -query $query
        $numerictypes = @("numeric","decimal")
        $maxlengthtypes = @("varchar", "nvarchar", "char", "nchar", "varbinary")
        #build table creation command
        foreach ($column in $columns) {
            if (($columnarray.Length -eq 0) -or ($columnarray -contains $column.COLUMN_NAME)) {
                $typeexpression = $column.DATA_TYPE
                if ($numerictypes -contains $column.DATA_TYPE) {
                    $typeexpression += "(" + $column.NUMERIC_PRECISION.ToString() + "," + $column.NUMERIC_SCALE.ToString() + ")"
                } elseif ($maxlengthtypes -contains $column.DATA_TYPE) {
                    $typeexpression = $column.DATA_TYPE + "("
                    if ($modifiertable.ContainsKey($column.COLUMN_NAME)) {
                        $typeexpression += $modifiertable[$column.COLUMN_NAME].ToString() + ")"
                    } elseif ($column.CHARACTER_MAXIMUM_LENGTH -eq -1) {
                        $typeexpression += "max)"
                    } else {
                        $typeexpression += $column.CHARACTER_MAXIMUM_LENGTH.ToString() + ")"
                    }
                } 
                $creationcmd += "`r`n[" + $column.COLUMN_NAME + "] " + $typeexpression
                if ($column.IS_NULLABLE -eq "YES") {
                    $creationcmd += " NULL"
                } else {
                    $creationcmd += " NOT NULL"
                }
                $creationcmd += ","
            }
        }
        #create the table        
        invoke-slave ($creationcmd.trimend(",") + "`r`n)")
        
        #get indexes from master
        $query = "
        declare @indextable table (name nvarchar(1000), description nvarchar(1000), keys nvarchar(1000))  
        insert into @indextable exec sp_helpIndex '$table'  
         
        select 'ALTER TABLE $table ADD CONSTRAINT ' + name + ' PRIMARY KEY ' + 
        case when description like '%nonclustered%' then 'NONCLUSTERED' else 'CLUSTERED' end + ' (' + replace(keys, '(-)', ' DESC') + ');' as indexcmd
        from @indextable where description like '%primary key%' 
        UNION ALL 
        select ISNULL('CREATE ' + case when description like '%nonclustered%' then 'NONCLUSTERED' else 'CLUSTERED' end +
        			 ' INDEX [' + name + '] on $table (' + replace(keys, '(-)', ' DESC') + '); ', '') as indexcmd
        from @indextable where description not like '%primary key%'  "
        $indexes = Invoke-SqlCmd2 -serverinstance $master -database $masterdb -query $query
        #create same indexes on slave
        foreach ($index in $indexes) {    
            Invoke-Slave $index.indexcmd
        }
    } elseif ($slavetype -eq "Netezza") {
        $exists = invoke-slave ("select 1 from _v_table where objtype = 'TABLE' and tablename = '" + $table.ToUpper() + "'")
        if ($exists -ne $null) {
            invoke-slave ("DROP TABLE " + $table.ToUpper())
        }
        $createcmd = [string]::Format("CREATE TABLE {0} ( {1} ) DISTRIBUTE ON RANDOM;", $table, [string]::join(",`r`n",$cols))        
        invoke-slave $createcmd
    }
}

#insert table name and current change tracking version into tblCTInitialize
#this will only do anything for the first slave being initialized across multiple slaves
$query = "insert into CT_" + $masterdb + "..tblctinitialize 
select '$table', GETDATE(), 1, null, change_tracking_current_version() 
where not exists (select 1 from CT_" + $masterdb + "..tblctinitialize where tablename = '$table ')"
Invoke-SqlCmd2 -serverinstance $master -database $masterdb -query $query

#begin data copying
if ($slavetype -eq "MSSQL") {
    $selectexpression = ""
    if (($columnarray.Length -gt 0) -or ($modifiertable.Count -gt 0)) {
        #get columns from master
        $query = "SELECT COLUMN_NAME, DATA_TYPE
        FROM INFORMATION_SCHEMA.COLUMNS WITH(NOLOCK)
        WHERE TABLE_NAME = '$table' AND TABLE_SCHEMA = '$schema'" 
        $columns = Invoke-SqlCmd2 -serverinstance $master -database $masterdb -query $query
        $maxlengthtypes = @("varchar", "nvarchar", "char", "nchar", "varbinary")
        #build table creation command
        foreach ($column in $columns) {
            if (($columnarray.Length -eq 0) -or ($columnarray -contains $column.COLUMN_NAME)) {
                if ($selectexpression.Length -gt 0) {
                    $selectexpression += ","
                }
                if ($modifiertable.ContainsKey($column.COLUMN_NAME)) {
                    $selectexpression += "LEFT(CAST([" + $column.COLUMN_NAME + "] AS NVARCHAR(MAX)),"
                    $selectexpression += $modifiertable[$column.COLUMN_NAME].ToString() + ") as '" + $column.COLUMN_NAME + "'"
                } else {
                    $selectexpression += "[" + $column.COLUMN_NAME + "]"
                }                
            }
        }
    } else {  
        $selectexpression = "*"
    }            

    #copy the data
    $SrcConnStr = "Data Source=$master;Initial Catalog=$masterdb;Trusted_Connection=true;"
    $SrcConn  = New-Object System.Data.SqlClient.SQLConnection($SrcConnStr) 
    #need to come up with the appropriate select statement here
    $CmdText = "SELECT $selectexpression FROM " + $table 
    $cmdtext
    $SqlCommand = New-Object system.Data.SqlClient.SqlCommand($CmdText, $SrcConn)  
    $SqlCommand.CommandTimeout = 360000 
    $SrcConn.Open() 
    [System.Data.SqlClient.SqlDataReader] $SqlReader = $SqlCommand.ExecuteReader() 
     
    Try { 
        $DestConnStr = "Data Source=$slave;Initial Catalog=$slavedb;Trusted_Connection=true;"
        $bulkCopy = New-Object Data.SqlClient.SqlBulkCopy($DestConnStr) 
        $bulkCopy.BulkCopyTimeout = 360000
        $bulkCopy.DestinationTableName = $table 
        $bulkCopy.WriteToServer($sqlReader) 
        Write-Output "Table $table in $masterdb database on $master has been copied to $table in $slavedb database on $slave." 
    } Catch [System.Exception] { 
        $ex = $_.Exception 
        Throw "Failed to copy $SrcTable from $SrcDatabase on $SrcServer with error: " + $ex.Message 
    } Finally { 
        $SqlReader.close() 
        $SrcConn.Close() 
        $SrcConn.Dispose() 
        $bulkCopy.Close() 
    } 

} elseif ($slavetype -eq "Netezza") {
    $bcpselect = [string]::Format("SELECT {0} FROM {1}..{2}", 
        [string]::Join(",", $colexpressions), $masterdb, $table)    
    if ($bcpselect.length -gt 3800) {
        $query = "IF OBJECT_ID('[CTVWINIT_" + $table + "]') IS NOT NULL DROP VIEW [CTVWINIT_" + $table + "]"
        invoke-sqlcmd2 -serverinstance $master -database ("CT_" + $masterdb) -query $query
        $query = [string]::Format("CREATE VIEW [CTVWINIT_{0}] 
        AS {1}", $table, $bcpselect)
        $bcpselect = "SELECT * FROM [CTVWINIT_" + $table + "]"
    }    
    bcp.exe "$bcpselect" queryout $bcppath -c -S $master -T -t "|" -r\n
    if (!$?) {
        throw ("BCP command failed: $bcpselect" )
    }
    plink -ssh -l $sshuser -i $pkpath $slave $nzloadscript $slavedb.ToLower() $table.ToLower()    
} 


#if we are initializing multiple slaves we should only update tblCTInitialize when the last one is done
if (!$notlast) {
    $query = "update tblCTInitialize
    set inifinishtime = getdate(), inprogress = 0 
    where tablename = '$table'"
    Invoke-SqlCmd2 -serverinstance $master -database ("CT_" + $masterdb) -query $query
}